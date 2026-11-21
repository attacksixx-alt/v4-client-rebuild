-- Cubev4 focused client-only preview loader.
-- Replace YOUR_GITHUB_USERNAME before uploading this file.

local USERNAME = "YOUR_GITHUB_USERNAME"
local REPOSITORY = "v4-client-rebuild"
local BRANCH = "main"

if USERNAME == "YOUR_GITHUB_USERNAME" then
    error("[Cubev4] Edit loader.lua and replace YOUR_GITHUB_USERNAME first.", 0)
end

local BASE_URL = "https://raw.githubusercontent.com/" .. USERNAME .. "/" .. REPOSITORY .. "/" .. BRANCH

local function httpGet(url)
    local ok, body = pcall(function() return game:HttpGet(url) end)
    if not ok then error("[Cubev4] Download failed: " .. tostring(body), 0) end
    if type(body) ~= "string" or body == "" then error("[Cubev4] Empty response: " .. url, 0) end
    return body
end

if type(loadstring) ~= "function" then
    error("[Cubev4] This launcher requires an environment that exposes loadstring.", 0)
end

local source = httpGet(BASE_URL .. "/runtime.lua")
local entry, compileError = loadstring(source)
if type(entry) ~= "function" then
    error("[Cubev4] runtime.lua did not compile: " .. tostring(compileError), 0)
end

return entry({ baseUrl = BASE_URL })
