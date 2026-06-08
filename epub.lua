--[[--
EPUB handler for the Document Translator plugin.
Unpacks an EPUB, translates all XHTML content files preserving
HTML structure, then repacks using KOReader's native ZipWriter.

@module koplugin.translator.epub
--]]--

local DataStorage = require("datastorage")
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")
local Tr          = require("translator")

local M = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

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

local function runCmd(cmd)
    logger.dbg("Translator/epub: running:", cmd)
    local ok = os.execute(cmd)
    return ok == 0 or ok == true
end

local function tmpDir()
    local dir = DataStorage:getDataDir() .. "/translator_tmp"
    if lfs.attributes(dir, "mode") == "directory" then
        runCmd("rm -rf " .. dir)
    end
    lfs.mkdir(dir)
    return dir
end

local function collectFiles(dir, base, result)
    base   = base or dir
    result = result or {}
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then
            local full = dir .. "/" .. entry
            local rel  = full:sub(#base + 2)
            local mode = lfs.attributes(full, "mode")
            if mode == "file" then
                table.insert(result, { full = full, rel = rel })
            elseif mode == "directory" then
                collectFiles(full, base, result)
            end
        end
    end
    return result
end

--- Parse container.xml and OPF to find XHTML content files.
local function getContentFiles(epub_dir)
    local container, err = readFile(epub_dir .. "/META-INF/container.xml")
    if not container then
        return nil, "Cannot read container.xml: " .. tostring(err)
    end

    local opf_rel = container:match('full%-path="([^"]+)"')
    if not opf_rel then
        return nil, "Cannot find OPF path in container.xml"
    end

    local opf_path = epub_dir .. "/" .. opf_rel
    local opf_dir  = opf_path:match("(.+)/[^/]+$") or epub_dir
    local opf, err2 = readFile(opf_path)
    if not opf then return nil, "Cannot read OPF: " .. tostring(err2) end

    local files = {}
    for item in opf:gmatch("<item[^>]+>") do
        local media = item:match('media%-type="([^"]+)"') or ""
        local href  = item:match('href="([^"]+)"')
        if href and (media:find("xhtml") or media:find("html") or href:match("%.x?html$")) then
            table.insert(files, opf_dir .. "/" .. href)
        end
    end

    return files
end

-- ── Public ────────────────────────────────────────────────────────────────────

--- Translate an EPUB file, preserving all formatting.
-- Unpacks the EPUB, translates text nodes in each XHTML file,
-- and repacks using KOReader's native ZipWriter.
-- @string src_path   Path to the source EPUB
-- @string dst_path   Path for the translated output EPUB
-- @string engine     "google" or "deepl"
-- @string lang       Target language code
-- @string key        API key
-- @treturn bool      true on success, or nil + error message
function M.translate(src_path, dst_path, engine, lang, key)
    local tmp = tmpDir()

    if not runCmd(string.format('unzip -q "%s" -d "%s"', src_path, tmp)) then
        runCmd("rm -rf " .. tmp)
        return nil, "Failed to unzip EPUB"
    end

    local content_files, err = getContentFiles(tmp)
    if not content_files then
        runCmd("rm -rf " .. tmp)
        return nil, err
    end
    if #content_files == 0 then
        runCmd("rm -rf " .. tmp)
        return nil, "No XHTML content files found in EPUB"
    end

    for i, fpath in ipairs(content_files) do
        logger.dbg("Translator/epub: file", i, "/", #content_files, fpath)
        local content, ferr = readFile(fpath)
        if not content then
            runCmd("rm -rf " .. tmp)
            return nil, "Cannot read " .. fpath .. ": " .. tostring(ferr)
        end

        local translated, terr = Tr.translateHtmlNodes(content, engine, lang, key)
        if not translated then
            runCmd("rm -rf " .. tmp)
            return nil, "Translation error: " .. tostring(terr)
        end

        local ok2, werr = writeFile(fpath, translated)
        if not ok2 then
            runCmd("rm -rf " .. tmp)
            return nil, "Cannot write " .. fpath .. ": " .. tostring(werr)
        end
    end

    -- Repack with KOReader's native ZipWriter (no system zip needed)
    local ZipWriter = require("ffi/zipwriter")
    local zw = ZipWriter:new()
    if not zw:open(dst_path) then
        runCmd("rm -rf " .. tmp)
        return nil, "Cannot create output EPUB: " .. dst_path
    end

    local function addToZip(rel, content, no_compression)
        zw:_open_new_file_in_zip(rel)
        zw:_write_file_in_zip(content, no_compression)
        zw:_close_file_in_zip()
    end

    -- mimetype must be first and uncompressed per EPUB spec
    local mimetype = readFile(tmp .. "/mimetype") or "application/epub+zip"
    addToZip("mimetype", mimetype, true)

    for _, entry in ipairs(collectFiles(tmp)) do
        if entry.rel ~= "mimetype" then
            local content = readFile(entry.full)
            if content then addToZip(entry.rel, content, false) end
        end
    end

    zw:close()
    runCmd("rm -rf " .. tmp)
    return true
end

return M
