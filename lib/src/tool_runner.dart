// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dartdoc.tool_runner;

import 'dart:io' show Process, ProcessException;

import 'package:analyzer/file_system/file_system.dart';
import 'package:dartdoc/src/io_utils.dart';
import 'package:dartdoc/src/tool_definition.dart';
import 'package:path/path.dart' as p;
import 'dartdoc_options.dart';

typedef ToolErrorCallback = void Function(String message);
typedef FakeResultCallback = String Function(String tool,
    {List<String> args, String content});

/// Set a ceiling on how many tool instances can be in progress at once,
/// limiting both parallelization and the number of open temporary files.
final MultiFutureTracker<void> _toolTracker = MultiFutureTracker(4);

/// Can be called when the ToolRunner is no longer needed.
///
/// This will remove any temporary files created by the tool runner.
class ToolTempFileTracker {
  final ResourceProvider resourceProvider;
  final Folder temporaryDirectory;

  ToolTempFileTracker._(this.resourceProvider)
      : temporaryDirectory =
            resourceProvider.createSystemTemp('dartdoc_tools_');

  static ToolTempFileTracker _instance;

  static ToolTempFileTracker get instance => _instance;

  static ToolTempFileTracker createInstance(
          ResourceProvider resourceProvider) =>
      _instance ??= ToolTempFileTracker._(resourceProvider);

  int _temporaryFileCount = 0;

  Future<File> createTemporaryFile() async {
    _temporaryFileCount++;
    // TODO(srawlins): Assume [temporaryDirectory]'s path is always absolute.
    var tempFile = resourceProvider.getFile(resourceProvider.pathContext.join(
        resourceProvider.pathContext.absolute(temporaryDirectory.path),
        'input_$_temporaryFileCount'));
    tempFile.writeAsStringSync('');
    return tempFile;
  }

  /// Call once no more files are to be created.
  Future<void> dispose() async {
    if (temporaryDirectory.exists) {
      return temporaryDirectory.delete();
    }
  }
}

/// A helper class for running external tools.
class ToolRunner {
  /// Creates a new ToolRunner.
  ///
  /// Takes a [toolConfiguration] that describes all of the available tools.
  /// An optional `errorCallback` will be called for each error message
  /// generated by the tool.
  ToolRunner(this.toolConfiguration);

  final ToolConfiguration toolConfiguration;

  Future<void> _runSetup(
      String name,
      ToolDefinition tool,
      Map<String, String> environment,
      ToolErrorCallback toolErrorCallback) async {
    var isDartSetup = ToolDefinition.isDartExecutable(tool.setupCommand[0]);
    var args = tool.setupCommand.toList();
    String commandPath;

    if (isDartSetup) {
      commandPath = toolConfiguration.resourceProvider.resolvedExecutable;
    } else {
      commandPath = args.removeAt(0);
    }
    await _runProcess(
        name, '', commandPath, args, environment, toolErrorCallback);
    tool.setupComplete = true;
  }

  Future<String> _runProcess(
      String name,
      String content,
      String commandPath,
      List<String> args,
      Map<String, String> environment,
      ToolErrorCallback toolErrorCallback) async {
    String commandString() => ([commandPath] + args).join(' ');
    try {
      var result =
          await Process.run(commandPath, args, environment: environment);
      if (result.exitCode != 0) {
        toolErrorCallback('Tool "$name" returned non-zero exit code '
            '(${result.exitCode}) when run as "${commandString()}" from '
            '${pathContext.current}\n'
            'Input to $name was:\n'
            '$content\n'
            'Stderr output was:\n${result.stderr}\n');
        return '';
      } else {
        return result.stdout;
      }
    } on ProcessException catch (exception) {
      toolErrorCallback('Failed to run tool "$name" as '
          '"${commandString()}": $exception\n'
          'Input to $name was:\n'
          '$content');
      return '';
    }
  }

  /// Run a tool.  The name of the tool is the first argument in the [args].
  /// The content to be sent to to the tool is given in the optional [content],
  /// and the stdout of the tool is returned.
  ///
  /// The [args] must not be null, and it must have at least one member (the name
  /// of the tool).
  Future<String> run(List<String> args, ToolErrorCallback toolErrorCallback,
      {String content, Map<String, String> environment}) async {
    Future<String> runner;
    // Prevent too many tools from running simultaneously.
    await _toolTracker.addFutureFromClosure(() {
      runner = _run(args, toolErrorCallback,
          content: content, environment: environment);
      return runner;
    });
    return runner;
  }

  Future<String> _run(List<String> args, ToolErrorCallback toolErrorCallback,
      {String content, Map<String, String> environment}) async {
    assert(args != null);
    assert(args.isNotEmpty);
    content ??= '';
    environment ??= <String, String>{};
    var tool = args.removeAt(0);
    if (!toolConfiguration.tools.containsKey(tool)) {
      toolErrorCallback(
          'Unable to find definition for tool "$tool" in tool map. '
          'Did you add it to dartdoc_options.yaml?');
      return '';
    }
    var toolDefinition = toolConfiguration.tools[tool];
    var toolArgs = toolDefinition.command;
    // Ideally, we would just be able to send the input text into stdin, but
    // there's no way to do that synchronously, and converting dartdoc to an
    // async model of execution is a huge amount of work. Using dart:cli's
    // waitFor feels like a hack (and requires a similar amount of work anyhow
    // to fix order of execution issues). So, instead, we have the tool take a
    // filename as part of its arguments, and write the input to a temporary
    // file before running the tool synchronously.

    // Write the content to a temp file.
    var tmpFile = await ToolTempFileTracker.createInstance(
            toolConfiguration.resourceProvider)
        .createTemporaryFile();
    tmpFile.writeAsStringSync(content);

    // Substitute the temp filename for the "$INPUT" token, and all of the other
    // environment variables. Variables are allowed to either be in $(VAR) form,
    // or $VAR form.
    var envWithInput = {
      'INPUT': pathContext.absolute(tmpFile.path),
      'TOOL_COMMAND': toolDefinition.command[0],
      ...environment,
    };
    if (toolDefinition is DartToolDefinition) {
      // Put the original command path into the environment, because when it
      // runs as a snapshot, Platform.script (inside the tool script) refers to
      // the snapshot, and not the original script.  This way at least, the
      // script writer can use this instead of Platform.script if they want to
      // find out where their script was coming from as an absolute path on the
      // filesystem.
      envWithInput['DART_SNAPSHOT_CACHE'] = pathContext.absolute(
          SnapshotCache.createInstance(toolConfiguration.resourceProvider)
              .snapshotCache
              .path);
      if (toolDefinition.setupCommand != null) {
        envWithInput['DART_SETUP_COMMAND'] = toolDefinition.setupCommand[0];
      }
    }
    var substitutions = envWithInput.map<RegExp, String>((key, value) {
      var escapedKey = RegExp.escape(key);
      return MapEntry(RegExp('\\\$(\\($escapedKey\\)|$escapedKey\\b)'), value);
    });
    var argsWithInput = <String>[];
    for (var arg in args) {
      var newArg = arg;
      substitutions
          .forEach((regex, value) => newArg = newArg.replaceAll(regex, value));
      argsWithInput.add(newArg);
    }

    if (toolDefinition.setupCommand != null && !toolDefinition.setupComplete) {
      await _runSetup(tool, toolDefinition, envWithInput, toolErrorCallback);
    }

    argsWithInput = toolArgs + argsWithInput;
    var toolStateForArgs = await toolDefinition.toolStateForArgs(argsWithInput);
    var commandPath = toolStateForArgs.commandPath;
    argsWithInput = toolStateForArgs.args;
    var callCompleter = toolStateForArgs.onProcessComplete;

    if (callCompleter != null) {
      return _runProcess(tool, content, commandPath, argsWithInput,
              envWithInput, toolErrorCallback)
          .whenComplete(callCompleter);
    } else {
      return _runProcess(tool, content, commandPath, argsWithInput,
          envWithInput, toolErrorCallback);
    }
  }

  p.Context get pathContext => toolConfiguration.resourceProvider.pathContext;
}
