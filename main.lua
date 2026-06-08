--[[--
Document Translator Plugin for KOReader
Version: 2.1.0
License: MIT
--]]--

local DataStorage      = require("datastorage")
local InfoMessage      = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local ConfirmBox       = require("ui/widget/confirmbox")
local UIManager        = require("ui/uimanager")
local WidgetContainer  = require("ui/widget/container/widgetcontainer")
local lfs              = require("libs/libkoreader-lfs")

local Tr    = require("translator")
local Epub  = require("epub")
local Cache = require("translation_cache")

local Translator = WidgetContainer:extend{
    name        = "translator",
    api_engine  = "google",
    target_lang = "pt-BR",
    deepl_key   = "",
    google_key  = "",
}

local function translationsDir()
    local dir = DataStorage:getDataDir() .. "/translations"
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(dir)
    end
    return dir
end

local function readFile(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local c = f:read("*a"); f:close()
    return c
end

local function writeFile(path, content)
    local f, err = io.open(path, "wb")
    if not f then return false, err end
    f:write(content); f:close()
    return true
end

function Translator:translateDocument(doc_path)
    local ext = (doc_path:match("%.([^%.]+)$") or ""):lower()
    local supported = { epub=true, html=true, htm=true, txt=true }
    if not supported[ext] then
        UIManager:show(InfoMessage:new{
            text    = "Format ." .. ext .. " is not supported. Supported: EPUB, HTML, TXT.",
            timeout = 4,
        })
        return
    end

    local basename = doc_path:match("([^/]+)%.[^%.]+$") or "document"
    local out_ext  = (ext == "txt") and "txt" or ext
    local out_path = translationsDir() .. "/" .. basename .. "_traduzido." .. out_ext

    if lfs.attributes(out_path, "mode") == "file" then
        UIManager:show(ConfirmBox:new{
            text        = "A translation already exists. Open existing or translate again?",
            ok_text     = "Translate again",
            cancel_text = "Open existing",
            ok_callback     = function() self:_doTranslate(doc_path, out_path, ext) end,
            cancel_callback = function() self:_openTranslated(out_path) end,
        })
        return
    end

    self:_doTranslate(doc_path, out_path, ext)
end

function Translator:_doTranslate(doc_path, out_path, ext)
    local wait_msg = InfoMessage:new{ text = "Translating... please wait." }
    UIManager:show(wait_msg)
    UIManager:scheduleIn(0.1, function()
        local ok, err = self:_runTranslation(doc_path, out_path, ext)
        UIManager:close(wait_msg)
        if not ok then
            UIManager:show(InfoMessage:new{
                text    = "Translation failed: " .. tostring(err),
                timeout = 6,
            })
            return
        end
        self:_openTranslated(out_path)
    end)
end

function Translator:_runTranslation(doc_path, out_path, ext)
    local key = (self.api_engine == "deepl") and self.deepl_key or self.google_key

    if ext == "epub" then
        return Epub.translate(doc_path, out_path, self.api_engine, self.target_lang, key)
    elseif ext == "html" or ext == "htm" then
        local content, err = readFile(doc_path)
        if not content then return nil, err end
        local translated, terr = Tr.translateHtmlNodes(content, self.api_engine, self.target_lang, key)
        if not translated then return nil, terr end
        return writeFile(out_path, translated)
    elseif ext == "txt" then
        local content, err = readFile(doc_path)
        if not content then return nil, err end
        local translated, terr = Tr.translateText(content, self.api_engine, self.target_lang, key)
        if not translated then return nil, terr end
        return writeFile(out_path, translated)
    end

    return nil, "Unsupported format"
end

function Translator:_openTranslated(path)
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(path)
end

function Translator:showSettings()
    self.settings_dialog = MultiInputDialog:new{
        title  = "Translator settings",
        fields = {
            { text=self.target_lang, hint="e.g. pt-BR, en, es, fr",
              description="Target language" },
            { text=self.google_key,  hint="Leave empty for free endpoint",
              description="Google Translate API key" },
            { text=self.deepl_key,   hint="Required to use DeepL",
              description="DeepL API key" },
            { text=self.api_engine,  hint="google  or  deepl",
              description="Translation engine" },
        },
        buttons = {{
            { text="Cancel", id="close",
              callback=function() UIManager:close(self.settings_dialog) end },
            { text="Save", callback=function()
                local f = self.settings_dialog:getFields()
                self.target_lang = f[1] ~= "" and f[1] or self.target_lang
                self.google_key  = f[2]
                self.deepl_key   = f[3]
                self.api_engine  = (f[4] == "deepl") and "deepl" or "google"
                self:saveSettings()
                UIManager:close(self.settings_dialog)
                UIManager:show(InfoMessage:new{ text="Settings saved.", timeout=2 })
            end },
        }},
    }
    UIManager:show(self.settings_dialog)
end

function Translator:loadSettings()
    local LuaSettings = require("luasettings")
    local cfg = LuaSettings:open(DataStorage:getSettingsDir().."/translator.lua")
    self.api_engine  = cfg:readSetting("api_engine")  or self.api_engine
    self.target_lang = cfg:readSetting("target_lang") or self.target_lang
    self.deepl_key   = cfg:readSetting("deepl_key")   or self.deepl_key
    self.google_key  = cfg:readSetting("google_key")  or self.google_key
end

function Translator:saveSettings()
    local LuaSettings = require("luasettings")
    local cfg = LuaSettings:open(DataStorage:getSettingsDir().."/translator.lua")
    cfg:saveSetting("api_engine",  self.api_engine)
    cfg:saveSetting("target_lang", self.target_lang)
    cfg:saveSetting("deepl_key",   self.deepl_key)
    cfg:saveSetting("google_key",  self.google_key)
    cfg:flush()
end

function Translator:init()
    self:loadSettings()
    self.ui.menu:registerToMainMenu(self)
end

function Translator:addToMainMenu(menu_items)
    menu_items.translator = {
        text = "Translate document",
        sub_item_table = {
            {
                text = "Translate this document",
                callback = function()
                    local doc_path = self.ui.document and self.ui.document.file
                    if not doc_path then
                        UIManager:show(InfoMessage:new{
                            text="No document is open.", timeout=3 })
                        return
                    end
                    self:translateDocument(doc_path)
                end,
            },
            {
                text = "Clear translations",
                sub_item_table = {
                    {
                        text     = "Delete all translations",
                        callback = function() Cache.clearAll() end,
                    },
                    {
                        text     = "Delete selected translation",
                        callback = function() Cache.clearSelected() end,
                    },
                },
            },
            {
                text     = "Settings",
                callback = function() self:showSettings() end,
            },
        },
    }
end

return Translator
