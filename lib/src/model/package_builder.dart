// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/context_root.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/file_system/file_system.dart';
// ignore: implementation_imports
import 'package:analyzer/src/context/builder.dart' show EmbedderYamlLocator;
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart'
    show AnalysisContextCollectionImpl;
// ignore: implementation_imports
import 'package:analyzer/src/dart/sdk/sdk.dart'
    show EmbedderSdk, FolderBasedDartSdk;
// ignore: implementation_imports
import 'package:analyzer/src/generated/engine.dart' show AnalysisOptionsImpl;
// ignore: implementation_imports
import 'package:analyzer/src/generated/sdk.dart' show DartSdk;
import 'package:dartdoc/src/dartdoc_options.dart';
import 'package:dartdoc/src/logging.dart';
import 'package:dartdoc/src/model/model.dart' hide Package;
import 'package:dartdoc/src/package_config_provider.dart';
import 'package:dartdoc/src/package_meta.dart'
    show PackageMeta, PackageMetaProvider;
import 'package:dartdoc/src/render/renderer_factory.dart';
import 'package:dartdoc/src/runtime_stats.dart';
import 'package:dartdoc/src/special_elements.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p show Context;

/// Everything you need to instantiate a PackageGraph object for documenting.
abstract class PackageBuilder {
  // Builds package graph to be used by documentation generator.
  Future<PackageGraph> buildPackageGraph();
}

/// A package builder that understands pub package format.
class PubPackageBuilder implements PackageBuilder {
  final DartdocOptionContext _config;
  final PackageMetaProvider _packageMetaProvider;
  final PackageConfigProvider _packageConfigProvider;

  PubPackageBuilder(
    this._config,
    this._packageMetaProvider,
    this._packageConfigProvider, {
    @visibleForTesting bool skipUnreachableSdkLibraries = false,
  }) : _skipUnreachableSdkLibraries = skipUnreachableSdkLibraries;

  @override
  Future<PackageGraph> buildPackageGraph() async {
    if (!_config.sdkDocs) {
      if (_config.topLevelPackageMeta.requiresFlutter &&
          _config.flutterRoot == null) {
        // TODO(devoncarew): We may no longer need to emit this error.
        throw DartdocOptionError(
            'Top level package requires Flutter but FLUTTER_ROOT environment variable not set');
      }
    }

    var rendererFactory = const HtmlRenderFactory();
    runtimeStats.resetAccumulators([
      'elementTypeInstantiation',
      'modelElementCacheInsertion',
    ]);

    runtimeStats.startPerfTask('_calculatePackageMap');
    await _calculatePackageMap();
    runtimeStats.endPerfTask();

    runtimeStats.startPerfTask('getLibraries');
    var newGraph = PackageGraph.uninitialized(
      _config,
      _sdk,
      _embedderSdkUris.isNotEmpty,
      rendererFactory,
      _packageMetaProvider,
    );
    await _getLibraries(newGraph);
    runtimeStats.endPerfTask();

    logDebug('${DateTime.now()}: Initializing package graph...');
    runtimeStats.startPerfTask('initializePackageGraph');
    await newGraph.initializePackageGraph();
    runtimeStats.endPerfTask();

    runtimeStats.startPerfTask('initializeCategories');
    newGraph.initializeCategories();
    runtimeStats.endPerfTask();

    return newGraph;
  }

  late final DartSdk _sdk = _packageMetaProvider.defaultSdk ??
      FolderBasedDartSdk(
          _resourceProvider, _resourceProvider.getFolder(_config.sdkDir));

  EmbedderSdk? __embedderSdk;

  EmbedderSdk? get _embedderSdk {
    if (__embedderSdk == null && !_config.topLevelPackageMeta.isSdk) {
      __embedderSdk = EmbedderSdk(
          _resourceProvider, EmbedderYamlLocator(_packageMap).embedderYamls);
    }
    return __embedderSdk;
  }

  ResourceProvider get _resourceProvider =>
      _packageMetaProvider.resourceProvider;

  p.Context get _pathContext => _resourceProvider.pathContext;

  /// Do not call more than once for a given PackageBuilder.
  Future<void> _calculatePackageMap() async {
    _packageMap = <String, List<Folder>>{};
    var cwd = _resourceProvider.getResource(_config.inputDir) as Folder;
    var info = await _packageConfigProvider
        .findPackageConfig(_resourceProvider.getFolder(cwd.path));
    if (info == null) return;

    for (var package in info.packages) {
      var packagePath =
          _pathContext.normalize(_pathContext.fromUri(package.packageUriRoot));
      var resource = _resourceProvider.getResource(packagePath);
      if (resource is Folder) {
        _packageMap[package.name] = [resource];
      }
    }
  }

  late final Map<String, List<Folder>> _packageMap;

  late final AnalysisContextCollection _contextCollection =
      AnalysisContextCollectionImpl(
    includedPaths: [_config.inputDir],
    // TODO(jcollins-g): should we pass excluded directories here instead of
    // handling it ourselves?
    resourceProvider: _resourceProvider,
    sdkPath: _config.sdkDir,
    updateAnalysisOptions2: ({
      required AnalysisOptionsImpl analysisOptions,
      required ContextRoot contextRoot,
      required DartSdk sdk,
    }) =>
        analysisOptions
          ..warning = false
          ..lint = false,
  );

  List<String> get _sdkFilesToDocument => [
        for (var sdkLib in _sdk.sdkLibraries)
          _sdk.mapDartUri(sdkLib.shortName)!.fullName,
      ];

  /// Resolves a single library at [filePath] using the current analysis driver.
  ///
  /// If [filePath] is not a library, returns null.
  Future<DartDocResolvedLibrary?> _resolveLibrary(String filePath) async {
    logDebug('Resolving $filePath...');

    var analysisContext = _contextCollection.contextFor(_config.inputDir);
    // Allow dart source files with inappropriate suffixes (#1897).
    final library =
        await analysisContext.currentSession.getResolvedLibrary(filePath);
    if (library is ResolvedLibraryResult) {
      return DartDocResolvedLibrary(library);
    }
    return null;
  }

  Set<PackageMeta> _packageMetasForFiles(Iterable<String> files) => {
        for (var filename in files)
          _packageMetaProvider.fromFilename(filename)!,
      };

  /// Whether to skip unreachable libraries when gathering all of the libraries
  /// for the package graph.
  ///
  /// **TESTING ONLY**
  ///
  /// When generating dartdoc for any package, this flag should be `false`. This
  /// is used in tests to dramatically speed up unit tests.
  final bool _skipUnreachableSdkLibraries;

  /// A set containing known part file paths.
  ///
  /// This set is used to prevent resolving set files more than once.
  final _knownParts = <String>{};

  /// Discovers and resolves libraries, invoking [addLibrary] with each result.
  ///
  /// Uses [processedLibraries] to prevent calling [addLibrary] more than once
  /// with the same [LibraryElement]. Adds each [LibraryElement] found to
  /// [processedLibraries].
  ///
  /// [addingSpecials] indicates that only [SpecialClass]es are being resolved
  /// in this round.
  Future<void> _discoverLibraries(
    void Function(DartDocResolvedLibrary) addLibrary,
    Set<LibraryElement> processedLibraries,
    Set<String> files, {
    bool addingSpecials = false,
  }) async {
    files = {...files};
    // Discover Dart libraries in a loop. In each iteration of the loop, we take
    // a set of files (starting with the ones passed into the function), resolve
    // them, add them to the package graph via `addLibrary`, and then discover
    // which additional files need to be processed in the next loop. This
    // discovery depends on various options (TODO: which?), but the basic idea
    // is to take a file we've just processed, and add all of the files which
    // that file references via imports or exports, and add them to the set of
    // files to be processed.
    //
    // This loop may execute a few times. We know to stop looping when we have
    // added zero new files to process. This is tracked with `filesInLastPass`
    // and `filesInCurrentPass`.
    var filesInLastPass = <String>{};
    var filesInCurrentPass = <String>{};
    var processedFiles = <String>{};
    // When the loop discovers new files in a new package, it does extra work to
    // find all documentable files in that package, for the universal reference
    // scope. This variable tracks which packages we've seen so far.
    var knownPackages = <PackageMeta>{};
    if (!addingSpecials) {
      progressBarStart(files.length);
    }
    do {
      filesInLastPass = filesInCurrentPass;
      var newFiles = <String>{};
      if (!addingSpecials) {
        progressBarUpdateTickCount(files.length);
      }
      // Be careful here, not to accidentally stack up multiple
      // [DartDocResolvedLibrary]s, as those eat our heap.
      var libraryFiles = files.difference(_knownParts);

      for (var file in libraryFiles) {
        if (processedFiles.contains(file)) {
          continue;
        }
        processedFiles.add(file);
        if (!addingSpecials) {
          progressBarTick();
        }
        var resolvedLibrary = await _resolveLibrary(file);
        if (resolvedLibrary == null) {
          _knownParts.add(file);
          continue;
        }
        newFiles.addFilesReferencedBy(resolvedLibrary.element);
        if (processedLibraries.contains(resolvedLibrary.element)) {
          continue;
        }
        if (addingSpecials || _shouldIncludeLibrary(resolvedLibrary.element)) {
          addLibrary(resolvedLibrary);
          processedLibraries.add(resolvedLibrary.element);
        }
      }
      files.addAll(newFiles);
      if (!addingSpecials) {
        files.addAll(_includedExternalsFrom(newFiles));
      }

      var packages = _packageMetasForFiles(files.difference(_knownParts));
      filesInCurrentPass = {...files.difference(_knownParts)};

      if (!addingSpecials) {
        // To get canonicalization correct for non-locally documented packages
        // (so we can generate the right hyperlinks), it's vital that we add all
        // libraries in dependent packages. So if the analyzer discovers some
        // files in a package we haven't seen yet, add files for that package.
        for (var meta in packages.difference(knownPackages)) {
          if (meta.isSdk) {
            if (!_skipUnreachableSdkLibraries) {
              files.addAll(_sdkFilesToDocument);
            }
          } else {
            files.addAll(await _findFilesToDocumentInPackage(
              meta.dir.path,
              includeDependencies: false,
              filterExcludes: false,
            ).toList());
          }
        }
        knownPackages.addAll(packages);
      }
    } while (!filesInLastPass.containsAll(filesInCurrentPass));
    if (!addingSpecials) {
      progressBarComplete();
    }
  }

  /// Whether [libraryElement] should be included in the libraries-to-document.
  bool _shouldIncludeLibrary(LibraryElement libraryElement) =>
      _config.include.isEmpty || _config.include.contains(libraryElement.name);

  /// Returns all top level library files in the 'lib/' directory of the given
  /// package root directory.
  ///
  /// If [includeDependencies], then all top level library files in the 'lib/'
  /// directory of every package in [basePackageDir]'s package config are also
  /// included.
  Stream<String> _findFilesToDocumentInPackage(
    String basePackageDir, {
    required bool includeDependencies,
    required bool filterExcludes,
  }) async* {
    var packageDirs = {basePackageDir};

    if (includeDependencies) {
      var packageConfig = (await _packageConfigProvider
          .findPackageConfig(_resourceProvider.getFolder(basePackageDir)))!;
      for (var package in packageConfig.packages) {
        if (filterExcludes && _config.exclude.contains(package.name)) {
          continue;
        }
        packageDirs.add(_pathContext.dirname(
            _pathContext.fromUri(packageConfig[package.name]!.packageUriRoot)));
      }
    }

    var sep = _pathContext.separator;
    var packagesWithSeparators = '${sep}packages$sep';
    for (var packageDir in packageDirs) {
      var packageLibDir = _pathContext.join(packageDir, 'lib');
      var packageLibSrcDir = _pathContext.join(packageLibDir, 'src');
      var packageDirContainsPackages =
          packageDir.contains(packagesWithSeparators);
      // To avoid analyzing package files twice, only files with paths not
      // containing '/packages/' will be added. The only exception is if the
      // file to analyze already has a '/packages/' in its path.
      for (var filePath in _listDir(packageDir, const {})) {
        if (!filePath.endsWith('.dart')) continue;
        if (!packageDirContainsPackages &&
            filePath.contains(packagesWithSeparators)) {
          // The package's directory path does not contain '/packages/' and this
          // file's path _does_, so it should not be included.
          continue;
        }

        // Only include libraries within the lib dir that are not in 'lib/src'.
        if (!_pathContext.isWithin(packageLibDir, filePath) ||
            _pathContext.isWithin(packageLibSrcDir, filePath)) {
          continue;
        }

        yield filePath;
      }
    }
  }

  /// Lists the files in [directory].
  ///
  /// Excludes files and directories beginning with `.`.
  ///
  /// The returned paths are guaranteed to begin with [directory].
  Iterable<String> _listDir(
      String directory, Set<String> listedDirectories) sync* {
    // Avoid recursive symlinks.
    var resolvedPath =
        _resourceProvider.getFolder(directory).resolveSymbolicLinksSync().path;
    if (listedDirectories.contains(resolvedPath)) {
      return;
    }

    listedDirectories = {
      ...listedDirectories,
      resolvedPath,
    };

    for (var resource
        in _packageDirList(_resourceProvider.getFolder(directory))) {
      // Skip hidden files and directories.
      if (_pathContext.basename(resource.path).startsWith('.')) {
        continue;
      }

      if (resource is File) {
        yield resource.path;
        continue;
      }
      if (resource is Folder) {
        yield* _listDir(resource.path, listedDirectories);
      }
    }
  }

  /// Calculates 'includeExternal' based on a list of files.
  ///
  /// Assumes each file might be part of a [DartdocOptionContext], and loads
  /// those objects to find any [DartdocOptionContext.includeExternal]
  /// configurations therein.
  List<String> _includedExternalsFrom(Iterable<String> files) => [
        for (var file in files)
          ...DartdocOptionContext.fromContext(
            _config,
            _config.resourceProvider.getFile(file),
            _config.resourceProvider,
          ).includeExternal,
      ];

  /// Returns the set of files that may contain elements that need to be
  /// documented.
  ///
  /// This takes into account the 'auto-include-dependencies' option, the
  /// 'exclude' option, and the 'include-external' option.
  Future<Set<String>> _getFilesToDocument() async {
    var files = _config.topLevelPackageMeta.isSdk
        ? _sdkFilesToDocument
        : await _findFilesToDocumentInPackage(
            _config.inputDir,
            includeDependencies: _config.autoIncludeDependencies,
            filterExcludes: true,
          ).toList();
    files = [...files, ..._includedExternalsFrom(files)];
    return {
      ...files
          .map((s) => _pathContext.absolute(_resourceProvider.getFile(s).path)),
      ..._embedderSdkFiles,
    };
  }

  Iterable<String> get _embedderSdkFiles => [
        for (var dartUri in _embedderSdkUris)
          _pathContext.absolute(_resourceProvider
              .getFile(_embedderSdk!.mapDartUri(dartUri)!.fullName)
              .path),
      ];

  Iterable<String> get _embedderSdkUris {
    if (_config.topLevelPackageMeta.isSdk) return const [];

    return _embedderSdk?.urlMappings.keys ?? const [];
  }

  /// Adds all libraries with documentable elements to
  /// [uninitializedPackageGraph].
  Future<void> _getLibraries(PackageGraph uninitializedPackageGraph) async {
    var embedderSdk = _embedderSdk;
    var findSpecialsSdk = switch (embedderSdk) {
      EmbedderSdk(:var urlMappings) when urlMappings.isNotEmpty => embedderSdk,
      _ => _sdk,
    };
    var files = await _getFilesToDocument();
    var specialFiles = specialLibraryFiles(findSpecialsSdk);

    logInfo('Discovering libraries...');
    var foundLibraries = <LibraryElement>{};
    await _discoverLibraries(
      uninitializedPackageGraph.addLibraryToGraph,
      foundLibraries,
      files,
    );
    _checkForMissingIncludedFiles(foundLibraries);
    await _discoverLibraries(
      uninitializedPackageGraph.addSpecialLibraryToGraph,
      foundLibraries,
      specialFiles.difference(files),
      addingSpecials: true,
    );
  }

  /// Throws an exception if any configured-to-be-included files were not found
  /// while gathering libraries.
  void _checkForMissingIncludedFiles(Set<LibraryElement> foundLibraries) {
    if (_config.include.isNotEmpty) {
      var knownLibraryNames = foundLibraries.map((l) => l.name);
      var notFound = _config.include
          .difference(Set.of(knownLibraryNames))
          .difference(_config.exclude);
      if (notFound.isNotEmpty) {
        throw StateError('Did not find: [${notFound.join(', ')}] in '
            'known libraries: [${knownLibraryNames.join(', ')}]');
      }
    }
  }

  /// Returns the children of [directory], or returns only the 'lib/'
  /// directory in [directory] if [directory] is determined to be a package
  /// root.
  ///
  /// This ensures that packages don't have non-`lib` content documented.
  static List<Resource> _packageDirList(Folder directory) {
    var resources = directory.getChildren();
    var pubspec = directory.getChild('pubspec.yaml');
    var libDirectory = directory.getChild('lib');

    return [
      if (pubspec is File && libDirectory is Folder)
        libDirectory
      else
        ...resources
    ];
  }
}

/// Contains the [ResolvedLibraryResult] and any additional information about
/// the library.
class DartDocResolvedLibrary {
  final LibraryElement element;
  final List<CompilationUnit> units;

  DartDocResolvedLibrary(ResolvedLibraryResult result)
      : element = result.element,
        units = result.units.map((unit) => unit.unit).toList();
}

extension on Set<String> {
  /// Adds [element]'s path and all of its part files' paths to `this`, and
  /// recursively adds the paths of all imported and exported libraries.
  void addFilesReferencedBy(LibraryElement? element) {
    if (element != null) {
      var path = element.source.fullName;
      if (add(path)) {
        for (var import in element.libraryImports) {
          addFilesReferencedBy(import.importedLibrary);
        }
        for (var export in element.libraryExports) {
          addFilesReferencedBy(export.exportedLibrary);
        }
        for (var part in element.parts
            .map((e) => e.uri)
            .whereType<DirectiveUriWithUnit>()) {
          add(part.source.fullName);
        }
      }
    }
  }
}
