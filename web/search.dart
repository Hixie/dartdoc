// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:html';
import 'package:dartdoc/src/search.dart';

import 'web_interop.dart';

final String _htmlBase = () {
  final body = document.querySelector('body')!;

  // If dartdoc did not add a base-href tag, we will need to add the relative
  // path ourselves.
  if (body.attributes['data-using-base-href'] == 'false') {
    // Dartdoc stores the htmlBase in 'body[data-base-href]'.
    return body.attributes['data-base-href'] ?? '';
  } else {
    return '';
  }
}();

void init() {
  var searchBox = document.getElementById('search-box') as InputElement?;
  var searchBody = document.getElementById('search-body') as InputElement?;
  var searchSidebar =
      document.getElementById('search-sidebar') as InputElement?;

  void disableSearch() {
    print('Could not activate search functionality.');

    searchBox?.placeholder = 'Failed to initialize search';
    searchBody?.placeholder = 'Failed to initialize search';
    searchSidebar?.placeholder = 'Failed to initialize search';
  }

  window.fetch('${_htmlBase}index.json').then((response) async {
    response = response as FetchResponse;
    var code = response.status;
    if (code == 404) {
      disableSearch();
      return;
    }

    var text = await response.text;
    final index = Index.fromJson(text);

    // Navigate to the first result from the 'search' query parameter
    // if specified and found.
    final url = Uri.parse(window.location.toString());
    final searchQuery = url.queryParameters['search'];
    if (searchQuery != null) {
      final matches = index.find(searchQuery);
      if (matches.isNotEmpty) {
        final href = matches.first.href;
        if (href != null) {
          window.location.assign('$_htmlBase$href');
          return;
        }
      }
    }

    // Initialize all three search fields.
    if (searchBox != null) {
      _Search(index).initialize(searchBox);
    }
    if (searchBody != null) {
      _Search(index).initialize(searchBody);
    }
    if (searchSidebar != null) {
      _Search(index).initialize(searchSidebar);
    }
  });
}

int _suggestionLimit = 10;
int _suggestionLength = 0;
const _htmlEscape = HtmlEscape();

/// A limited tree of element containers.
///
/// Each key is the inner HTML of a container suggestion element. Each value is
/// an element for the container, and which contains one or more child
/// suggestions, all of whom have the container as their parent. This is only
/// useful for the search results page.
final _containerMap = <String, Element>{};

class _Search {
  final Index index;
  final Uri uri;

  late final listBox = document.createElement('div')
    ..setAttribute('role', 'listbox')
    ..setAttribute('aria-expanded', 'false')
    ..style.display = 'none'
    ..classes.add('tt-menu')
    ..append(moreResults)
    ..append(searchResults);

  /// Element used in [listBox] to inform the functionality of hitting enter in
  /// search box.
  late final moreResults = document.createElement('div')
    ..classes.add('enter-search-message');

  /// Element that contains the search suggestions in a new format.
  late final searchResults = document.createElement('div')
    ..classes.add('tt-search-results');

  String? storedValue;
  String actualValue = '';
  final List<Element> suggestionElements = <Element>[];
  List<IndexItem> suggestionsInfo = <IndexItem>[];
  int selectedElement = -1;

  _Search(this.index) : uri = Uri.parse(window.location.href);

  void initialize(InputElement inputElement) {
    inputElement.disabled = false;
    inputElement.setAttribute('placeholder', 'Search API Docs');
    // Handle grabbing focus when the user types '/' outside of the input.
    document.addEventListener('keydown', (Event event) {
      if (event is! KeyboardEvent) {
        return;
      }
      if (event.key == '/' && document.activeElement is! InputElement) {
        event.preventDefault();
        inputElement.focus();
      }
    });

    // Prepare elements.
    var wrapper = document.createElement('div')..classes.add('tt-wrapper');
    inputElement
      ..replaceWith(wrapper)
      ..setAttribute('autocomplete', 'off')
      ..setAttribute('spellcheck', 'false')
      ..classes.add('tt-input');

    wrapper
      ..append(inputElement)
      ..append(listBox);

    setEventListeners(inputElement);

    // Display the search results in the main body, if we're rendering the
    // search page.
    if (window.location.href.contains('search.html')) {
      var query = uri.queryParameters['q'];
      if (query == null) {
        return;
      }
      query = _htmlEscape.convert(query);
      _suggestionLimit = _suggestionLength;
      handleSearch(query, isSearchPage: true);
      showSearchResultPage(query);
      hideSuggestions();
      _suggestionLimit = 10;
    }
  }

  /// Displays the suggestions [searchResults] list box.
  void showSuggestions() {
    if (searchResults.hasChildNodes()) {
      listBox
        ..style.display = 'block'
        ..setAttribute('aria-expanded', 'true');
    }
  }

  /// Creates the content displayed in the main-content element, for the search
  /// results page.
  void showSearchResultPage(String searchText) {
    final mainContent = document.getElementById('dartdoc-main-content');

    if (mainContent == null) {
      return;
    }

    mainContent
      ..text = ''
      ..append(document.createElement('section')..classes.add('search-summary'))
      ..append(document.createElement('h2')..innerHtml = 'Search Results')
      ..append(document.createElement('div')
        ..classes.add('search-summary')
        ..innerHtml = '$_suggestionLength results for "$searchText"');

    if (_containerMap.isNotEmpty) {
      for (final element in _containerMap.values) {
        mainContent.append(element);
      }
    } else {
      var noResults = document.createElement('div')
        ..classes.add('search-summary')
        ..innerHtml =
            'There was not a match for "$searchText". Want to try searching '
                'from additional Dart-related sites? ';

      var buildLink = Uri.parse(
              'https://dart.dev/search?cx=011220921317074318178%3A_yy-tmb5t_i&ie=UTF-8&hl=en&q=')
          .replace(queryParameters: {'q': searchText});
      var link = document.createElement('a')
        ..setAttribute('href', buildLink.toString())
        ..text = 'Search on dart.dev.';
      noResults.append(link);
      mainContent.append(noResults);
    }
  }

  void hideSuggestions() => listBox
    ..style.display = 'none'
    ..setAttribute('aria-expanded', 'false');

  void showEnterMessage() => moreResults.text = _suggestionLength > 10
      ? 'Press "Enter" key to see all $_suggestionLength results'
      : '';

  /// Updates the suggestions displayed below the search bar to [suggestions].
  ///
  /// [query] is only required here so that it can be displayed with emphasis
  /// (as a prefix, for example).
  void updateSuggestions(String query, List<IndexItem> suggestions,
      {bool isSearchPage = false}) {
    suggestionsInfo = [];
    suggestionElements.clear();
    _containerMap.clear();
    searchResults.text = '';

    if (suggestions.isEmpty) {
      hideSuggestions();
      return;
    }

    for (final suggestion in suggestions) {
      suggestionElements.add(_createSuggestion(query, suggestion));
    }

    var suggestionSource =
        isSearchPage ? _containerMap.values : suggestionElements;
    for (final element in suggestionSource) {
      searchResults.append(element);
    }
    suggestionsInfo = suggestions;

    removeSelectedElement();

    showSuggestions();
    showEnterMessage();
  }

  /// Handles [searchText] by generating suggestions.
  void handleSearch(String? searchText,
      {bool forceUpdate = false, bool isSearchPage = false}) {
    if (actualValue == searchText && !forceUpdate) {
      return;
    }

    if (searchText == null || searchText.isEmpty) {
      updateSuggestions('', []);
      return;
    }

    var suggestions = index.find(searchText);
    _suggestionLength = suggestions.length;
    if (suggestions.length > _suggestionLimit) {
      suggestions = suggestions.sublist(0, _suggestionLimit);
    }

    actualValue = searchText;
    updateSuggestions(searchText, suggestions, isSearchPage: isSearchPage);
  }

  /// Clears the search box and suggestions.
  void clearSearch(InputElement inputElement) {
    removeSelectedElement();
    if (storedValue != null) {
      inputElement.value = storedValue;
      storedValue = null;
    }
    hideSuggestions();
  }

  void setEventListeners(InputElement inputElement) {
    inputElement.addEventListener('focus', (Event event) {
      handleSearch(inputElement.value, forceUpdate: true);
    });

    inputElement.addEventListener('blur', (Event event) {
      clearSearch(inputElement);
    });

    inputElement.addEventListener('input', (event) {
      handleSearch(inputElement.value);
    });

    inputElement.addEventListener('keydown', (Event event) {
      if (event.type != 'keydown') {
        return;
      }

      event = event as KeyboardEvent;

      if (event.code == 'Enter') {
        event.preventDefault();
        if (!selectedElement.isBlurred) {
          var href = suggestionElements[selectedElement].dataset['href'];
          if (href != null) {
            window.location.assign('$_htmlBase$href');
          }
          return;
        }
        // If there is no search suggestion selected, then change the window
        // location to `search.html`.
        else {
          var query = _htmlEscape.convert(actualValue);
          var searchPath = Uri.parse('${_htmlBase}search.html')
              .replace(queryParameters: {'q': query});
          window.location.assign(searchPath.toString());
          return;
        }
      }

      var lastIndex = suggestionElements.length - 1;
      var previousSelectedElement = selectedElement;

      if (event.code == 'ArrowUp') {
        if (selectedElement.isBlurred) {
          selectedElement = lastIndex;
        } else {
          selectedElement = selectedElement - 1;
        }
      } else if (event.code == 'ArrowDown') {
        if (selectedElement == lastIndex) {
          removeSelectedElement();
        } else {
          selectedElement = selectedElement + 1;
        }
      } else if (event.code == 'Escape') {
        clearSearch(inputElement);
      } else {
        if (storedValue != null) {
          storedValue = null;
          handleSearch(inputElement.value);
        }
        return;
      }

      if (!previousSelectedElement.isBlurred) {
        suggestionElements[previousSelectedElement].classes.remove('tt-cursor');
      }

      if (!selectedElement.isBlurred) {
        var selected = suggestionElements[selectedElement];
        selected.classes.add('tt-cursor');

        // Guarantee the selected element is visible.
        if (selectedElement == 0) {
          listBox.scrollTop = 0;
        } else if (selectedElement == lastIndex) {
          listBox.scrollTop = listBox.scrollHeight;
        } else {
          var offsetTop = selected.offsetTop;
          var parentOffsetHeight = listBox.offsetHeight;
          if (offsetTop < parentOffsetHeight ||
              parentOffsetHeight < (offsetTop + selected.offsetHeight)) {
            selected.scrollIntoView();
          }
        }

        // Store the actual input value to display their currently selected
        // item.
        storedValue ??= inputElement.value;
        inputElement.value = suggestionsInfo[selectedElement].name;
      } else if (storedValue != null && !previousSelectedElement.isBlurred) {
        // They are moving back to the input field, so return the stored value.
        inputElement.value = storedValue;
        storedValue = null;
      }

      event.preventDefault();
    });
  }

  /// Sets the selection index to `-1`.
  void removeSelectedElement() => selectedElement = -1;
}

Element _createSuggestion(String query, IndexItem match) {
  final suggestion = document.createElement('div')
    ..setAttribute('data-href', match.href ?? '')
    ..classes.add('tt-suggestion');

  final suggestionTitle = document.createElement('span')
    ..classes.add('tt-suggestion-title')
    ..innerHtml = _highlight(
        '${match.name} ${match.kind.toString().toLowerCase()}', query);
  suggestion.append(suggestionTitle);

  final enclosingElement = match.enclosedBy;
  if (enclosingElement != null) {
    suggestion.append(document.createElement('span')
      ..classes.add('tt-suggestion-container')
      ..innerHtml = '(in ${_highlight(enclosingElement.name, query)})');
  }

  // The one line description to use in the search suggestions.
  final matchDescription = match.desc;
  if (matchDescription != null && matchDescription.isNotEmpty) {
    final inputDescription = document.createElement('blockquote')
      ..classes.add('one-line-description')
      ..attributes['title'] = _decodeHtml(matchDescription)
      ..innerHtml = _highlight(matchDescription, query);
    suggestion.append(inputDescription);
  }

  suggestion.addEventListener('mousedown', (event) {
    event.preventDefault();
  });

  suggestion.addEventListener('click', (event) {
    if (match.href != null) {
      window.location.assign('$_htmlBase${match.href}');
      event.preventDefault();
    }
  });

  if (enclosingElement != null) {
    _mapToContainer(
      _createContainer(
        '${enclosingElement.name} ${enclosingElement.kind}',
        enclosingElement.href,
      ),
      suggestion,
    );
  }
  return suggestion;
}

/// Maps a suggestion library/class [Element] to the other suggestions, if any.
void _mapToContainer(Element containerElement, Element suggestion) {
  final containerInnerHtml = containerElement.innerHtml;

  if (containerInnerHtml == null) {
    return;
  }

  final element = _containerMap[containerInnerHtml];
  if (element != null) {
    element.append(suggestion);
  } else {
    containerElement.append(suggestion);
    _containerMap[containerInnerHtml] = containerElement;
  }
}

/// Creates an `<a>` [Element] for the enclosing library/class.
Element _createContainer(String encloser, String href) =>
    document.createElement('div')
      ..classes.add('tt-container')
      ..append(document.createElement('p')
        ..text = 'Results from '
        ..classes.add('tt-container-text')
        ..append(document.createElement('a')
          ..setAttribute('href', href)
          ..innerHtml = encloser));

/// Wraps each instance of [query] in [text] with a `<strong>` tag, as HTML
/// text.
String _highlight(String text, String query) => text.replaceAllMapped(
      RegExp(query, caseSensitive: false),
      (match) => "<strong class='tt-highlight'>${match[0]}</strong>",
    );

/// Decodes HTML entities (like `&lt;`) into their HTML elements (like `<`).
///
/// This is safe for use in an HTML attribute like `title`.
String _decodeHtml(String html) {
  return ((document.createElement('textarea') as TextAreaElement)
        ..innerHtml = html)
      .value!;
}

extension on int {
  // TODO(srawlins): Re-implement in inline class someday.
  bool get isBlurred => this == -1;
}
