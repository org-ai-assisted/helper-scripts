#!/usr/bin/python3 -Bsu

## Copyright (C) 2025 - 2025 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

# pylint: disable=unknown-option-value,broad-exception-caught

"""
strip_markup_lib.py: Library for stripping markup from a string.
"""

from io import StringIO
from html.parser import HTMLParser


## Inspired by https://stackoverflow.com/a/925630/19474638
class StripMarkupEngine(HTMLParser):
    """
    HTMLParser derivative that strips markup tags from its input.
    """

    def __init__(self) -> None:
        """
        Init function.
        """

        super().__init__()
        self.reset()
        self.convert_charrefs = True
        self.text: StringIO = StringIO()

    def handle_data(self, data: str) -> None:
        """
        Accumulates text extracted from markup.
        """

        self.text.write(data)

    def get_data(self) -> str:
        """
        Returns accumulated text extracted from markup.
        """

        return self.text.getvalue()


def _underscore_sanitize(text: str) -> str:
    """
    Neuter markup metacharacters when the parser path is unsafe.
    See https://stackoverflow.com/a/10371699/19474638
    """

    return "".join("_" if char in ["<", ">", "&"] else char for char in text)


def strip_markup(untrusted_string: str) -> str:
    """
    Stripping function.
    """

    markup_stripper: StripMarkupEngine = StripMarkupEngine()
    try:
        markup_stripper.feed(untrusted_string)
        ## close() is required: with convert_charrefs=True the parser buffers
        ## character data to coalesce entities and only flushes it at the next
        ## tag or on close(). Without close(), a tagless string that contains a
        ## '&' (e.g. any URL with a query string, "...?a=1&b=2") never reaches
        ## handle_data and get_data() returns "" - the whole value is silently
        ## dropped. That empties the confirmation dialog, hiding the link the
        ## user is being asked to confirm.
        markup_stripper.close()
    except Exception:
        ## CPython's HTMLParser raises uncaught exceptions on some
        ## malformed inputs (e.g. AssertionError on '<![...' patterns
        ## before gh-77057 landed). Sanitization must never propagate
        ## parser internals to the caller, so fall back to the
        ## underscore strategy on the original input.
        return _underscore_sanitize(untrusted_string)
    strip_one_string: str = markup_stripper.get_data()

    markup_stripper = StripMarkupEngine()
    try:
        markup_stripper.feed(strip_one_string)
        markup_stripper.close()
    except Exception:
        return _underscore_sanitize(strip_one_string)
    strip_two_string: str = markup_stripper.get_data()
    if strip_one_string == strip_two_string:
        ## A '<' that this parser does not treat as a tag (e.g. "< a href=...>",
        ## where whitespace after '<' defeats Python's html.parser) can still be
        ## revived into a tag by a more lenient downstream HTML parser, such as
        ## Qt's QTextDocument used by msgcollector's generic_gui_message. Neuter
        ## any residual tag-opening '<' so stripped output cannot be
        ## re-interpreted as markup. '>' and '&' alone cannot open a tag, and
        ## neutering them would corrupt legitimate text, so they are left as-is.
        return strip_one_string.replace("<", "_")

    ## If we get this far, the second strip attempt further transformed the
    ## text, indicating an attempt to maliciously circumvent the stripper.
    ## Sanitize the malicious text by underscore-replacing markup
    ## metacharacters.
    ##
    ## Note that we sanitize strip_one_string, NOT strip_two_string, so that
    ## the neutered malicious text is displayed to the user. This is so that
    ## the user is alerted to something odd happening.
    return _underscore_sanitize(strip_one_string)
