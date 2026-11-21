-- Cubev4 client rebuild bootstrap.
-- Replace YOUR_GITHUB_USERNAME with the owner of the public repository.

local BASE_URL = "https://raw.githubusercontent.com/attacksixx-alt/v4-client-rebuild/main"

local function fetch(url)
    local ok, body = pcall(function()
        return game:HttpGet(url)
    end)
    if not ok or type(body) ~= "string" or body == "" then
        error("[Cubev4] Could not download " .. url .. ": " .. tostring(body), 0)
    end
    return body
end

if type(loadstring) ~= "function" then
    error("[Cubev4] This environment does not expose loadstring.", 0)
end

local source = fetch(BASE_URL .. "/runtime.lua")
local runtime, compileError = loadstring(source)
if type(runtime) ~= "function" then
    error("[Cubev4] runtime.lua compilation failed: " .. tostring(compileError), 0)
end

return runtime({
    baseUrl = BASE_URL,
    manifestPath = "/data/manifest.json",
})
