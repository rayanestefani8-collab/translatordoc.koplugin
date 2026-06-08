--[[--
Cache manager for the Document Translator plugin.
Lists, deletes all, or deletes selected translated files
from koreader/translations/.
--]]--

local DataStorage = require("datastorage")
local ConfirmBox  = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager   = require("ui/uimanager")
local lfs         = require("libs/libkoreader-lfs")
local Screen      = require("device").screen

local M = {}

local function translationsDir()
    local dir = DataStorage:getDataDir() .. "/translations"
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(dir)
    end
    return dir
end

local function listFiles()
    local dir   = translationsDir()
    local files = {}
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then
            local full = dir .. "/" .. entry
            if lfs.attributes(full, "mode") == "file" then
                table.insert(files, { name = entry, path = full })
            end
        end
    end
    table.sort(files, function(a, b) return a.name < b.name end)
    return files
end

function M.clearAll()
    UIManager:show(ConfirmBox:new{
        text    = "Delete all translated documents? This cannot be undone.",
        ok_text = "Delete all",
        ok_callback = function()
            local files = listFiles()
            local count = 0
            for _, f in ipairs(files) do
                if os.remove(f.path) then count = count + 1 end
            end
            UIManager:show(InfoMessage:new{
                text    = "Deleted " .. count .. " translated document(s).",
                timeout = 3,
            })
        end,
    })
end

function M.clearSelected()
    local files = listFiles()
    if #files == 0 then
        UIManager:show(InfoMessage:new{
            text    = "No translated documents found.",
            timeout = 3,
        })
        return
    end

    local Menu = require("ui/widget/menu")
    local menu_ref = {}

    local items = {}
    for _, f in ipairs(files) do
        local fname = f.name
        local fpath = f.path
        table.insert(items, {
            text = fname,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text    = "Delete: " .. fname,
                    ok_text = "Delete",
                    ok_callback = function()
                        os.remove(fpath)
                        if menu_ref[1] then
                            UIManager:close(menu_ref[1])
                        end
                        UIManager:show(InfoMessage:new{
                            text    = "Deleted: " .. fname,
                            timeout = 2,
                        })
                    end,
                })
            end,
        })
    end

    local m = Menu:new{
        title        = "Select translation to delete",
        item_table   = items,
        onMenuSelect = function(_, item) item.callback() end,
        onMenuHold   = function() end,
        width        = math.floor(Screen:getWidth()  * 0.9),
        height       = math.floor(Screen:getHeight() * 0.7),
    }
    menu_ref[1] = m
    UIManager:show(m)
end

return M
