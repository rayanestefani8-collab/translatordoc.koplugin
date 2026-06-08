local _ = require("gettext")
return {
    name = "translator",
    fullname = _("Document Translator"),
    description = _([[Translates the current document (EPUB, HTML, TXT) using Google Translate or DeepL, and saves the result as a new file in koreader/translations/.]]),
}
