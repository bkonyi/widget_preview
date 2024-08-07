// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:dart_style/dart_style.dart';
import 'package:logging/logging.dart';
import 'package:code_builder/code_builder.dart' as builder;
import 'package:watcher/watcher.dart';

import 'flutter_tools_daemon.dart';
import 'utils.dart';
import 'widget_preview_scaffold.dart';

/// Clears preview scaffolding state on each run.
///
/// Set to false for release.
const developmentMode = true;

const previewScaffoldProjectPath = '.dart_tool/preview_scaffold/';

final logger = Logger.root;

typedef PreviewMapping = Map<String, List<String>>;

class WidgetPreviewEnvironment {
  final _pathToPreviews = PreviewMapping();
  StreamSubscription<WatchEvent>? _fileWatcher;

  Future<void> start(Directory projectRoot) async {
    // TODO(bkonyi): consider parallelizing initializing the scaffolding
    // project and finding the previews.
    await _ensurePreviewScaffoldExists();
    _pathToPreviews.addAll(_findPreviewFunctions(projectRoot));
    await _populatePreviewsInScaffold(_pathToPreviews);
    await _runPreviewEnvironment();
    await _cleanup();
  }

  Future<void> _cleanup() async {
    await _fileWatcher?.cancel();
  }

  Future<void> _ensurePreviewScaffoldExists() async {
    // TODO(bkonyi): check for .dart_tool explicitly
    if (developmentMode) {
      final previewScaffoldProject = Directory(previewScaffoldProjectPath);
      if (previewScaffoldProject.existsSync()) {
        previewScaffoldProject.deleteSync(recursive: true);
      }
    }
    if (Directory(previewScaffoldProjectPath).existsSync()) {
      logger.info('Preview scaffolding exists!');
      return;
    }

    // TODO(bkonyi): check exit code.
    logger.info('Creating $previewScaffoldProjectPath...');
    Process.runSync('flutter', [
      'create',
      '--platforms=windows,linux,macos',
      '.dart_tool/preview_scaffold',
    ]);

    if (!Directory(previewScaffoldProjectPath).existsSync()) {
      logger.severe('Could not create $previewScaffoldProjectPath!');
      throw StateError('Could not create $previewScaffoldProjectPath');
    }

    logger.info(Uri(path: previewScaffoldProjectPath).resolve('lib/main.dart'));
    logger.info('Writing preview scaffolding entry point...');
    File(Uri(path: previewScaffoldProjectPath)
            .resolve('lib/main.dart')
            .toString())
        .writeAsStringSync(
      widgetPreviewScaffold,
      mode: FileMode.write,
    );

    // TODO(bkonyi): add dependency on published package:widget_preview or
    // remove this if it's shipped with package:flutter
    logger.info('Adding package:widget_preview dependency...');
    final args = [
      'pub',
      'add',
      '--directory=.dart_tool/preview_scaffold',
      "widget_preview:{\"path\":\"../widget_preview\"}"
    ];
    // TODO(bkonyi): check exit code.
    Process.runSync('flutter', args);

    // Generate an empty 'lib/generated_preview.dart'
    logger.info(
      'Generating empty ${previewScaffoldProjectPath}lib/generated_preview.dart',
    );

    await _populatePreviewsInScaffold(const <String, List<String>>{});

    logger.info('Performing initial build...');
    await _initialBuild();

    logger.info('Preview scaffold initialization complete!');
  }

  Future<void> _initialBuild() async {
    await runInDirectoryScope(
      path: previewScaffoldProjectPath,
      callback: () {
        assert(Platform.isLinux || Platform.isMacOS || Platform.isWindows);
        final args = <String>[
          'build',
          // This assumes the device ID string matches the subcommand name.
          PlatformUtils.getDeviceIdForPlatform(),
          '--device-id=${PlatformUtils.getDeviceIdForPlatform()}',
          '--debug',
        ];
        // TODO(bkonyi): check exit code.
        Process.runSync('flutter', args);
      },
    );
  }

  /// Search for functions annotated with `@Preview` in the current project.
  PreviewMapping _findPreviewFunctions(FileSystemEntity entity) {
    final collection = AnalysisContextCollection(
      includedPaths: [entity.absolute.path],
      resourceProvider: PhysicalResourceProvider.INSTANCE,
    );

    final previews = PreviewMapping();

    for (final context in collection.contexts) {
      logger.info('Finding previews in ${context.contextRoot.root.path} ...');

      for (final filePath in context.contextRoot.analyzedFiles()) {
        if (!filePath.endsWith('.dart')) {
          continue;
        }

        final lib = context.currentSession.getParsedLibrary(filePath)
            as ParsedLibraryResult;
        for (final unit in lib.units) {
          for (final entity in unit.unit.childEntities) {
            if (entity is FunctionDeclaration &&
                !entity.name.toString().startsWith('_')) {
              bool foundPreview = false;
              for (final annotation in entity.metadata) {
                if (annotation.name.name == 'Preview') {
                  // What happens if the annotation is applied multiple times?
                  foundPreview = true;
                  break;
                }
              }
              if (foundPreview) {
                logger.info('File path: ${Uri.file(filePath.toString())}');
                logger.info('Preview function: ${entity.name}');
                previews
                    .putIfAbsent(
                      Uri.file(filePath.toString()).toString(),
                      () => <String>[],
                    )
                    .add(entity.name.toString());
              }
            }
          }
        }
      }
    }
    return previews;
  }

  Future<void> _populatePreviewsInScaffold(PreviewMapping previews) async {
    final lib = builder.Library(
      (b) => b.body.addAll(
        [
          builder.Directive.import(
            'package:widget_preview/widget_preview.dart',
          ),
          builder.Method(
            (b) => b
              ..body = builder.literalList(
                [
                  for (final MapEntry(
                        key: String path,
                        value: List<String> previewMethods
                      ) in previews.entries) ...[
                    for (final method in previewMethods)
                      builder.refer(method, path).spread.call([]),
                  ],
                ],
              ).code
              ..name = 'previews'
              ..returns = builder.refer('List<WidgetPreview>'),
          )
        ],
      ),
    );
    final emitter = builder.DartEmitter.scoped(useNullSafetySyntax: true);
    await File(
      Directory.current.absolute.uri
          .resolve('.dart_tool/preview_scaffold/lib/generated_preview.dart')
          .toFilePath(),
    ).writeAsString(
      DartFormatter().format('${lib.accept(emitter)}'),
    );
  }

  Future<void> _runPreviewEnvironment() async {
    final projectDir = Directory.current.uri.toFilePath();
    final process = await runInDirectoryScope<Process>(
      path: previewScaffoldProjectPath,
      callback: () async {
        final args = [
          'run',
          '--machine',
          '--use-application-binary=${PlatformUtils.prebuiltApplicationBinaryPath}',
          '--device-id=${PlatformUtils.getDeviceIdForPlatform()}',
        ];
        logger.info('Running "flutter $args"');
        return await Process.start('flutter', args);
      },
    );

    final daemon = Daemon(
      // Immediately trigger a hot restart on app start to update state
      onAppStart: (String appId) => process.stdin.writeln(
        DaemonRequest.hotRestart(appId: appId).encode(),
      ),
    );

    process.stdout.transform(utf8.decoder).listen((e) {
      logger.info('[STDOUT] ${e.withNoTrailingNewLine}');
      daemon.handleEvent(e);
    });

    process.stderr.transform(utf8.decoder).listen((e) {
      if (e == '\n') return;
      logger.info('[STDERR] ${e.withNoTrailingNewLine}');
    });

    _fileWatcher = Watcher(projectDir).events.listen((event) {
      if (daemon.appId == null ||
          !event.path.endsWith('.dart') ||
          event.path.endsWith('generated_preview.dart')) return;
      final path = Uri.file(event.path).toString();
      logger.info('Detected change in $path. Performing reload...');

      final filePreviews = _findPreviewFunctions(File(event.path))[path];
      logger.info('Updated previews for $path: $filePreviews');
      if (filePreviews?.isNotEmpty ?? false) {
        final currentPreviewsForFile = _pathToPreviews[path];
        if (filePreviews != currentPreviewsForFile) {
          _pathToPreviews[path] = filePreviews!;
        }
      } else {
        _pathToPreviews.remove(path);
      }
      _populatePreviewsInScaffold(_pathToPreviews);

      process.stdin.writeln(
        DaemonRequest.hotReload(appId: daemon.appId!).encode(),
      );
    });

    await process.exitCode;
  }
}