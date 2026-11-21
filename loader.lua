-- Cubev4 client rebuild bootstrap
-- Replace YOUR_USERNAME with the owner of the GitHub repository.

local BASE_URL = "https://raw.githubusercontent.com/YOUR_USERNAME/cubev4-client-rebuild/main"

local function fetch(url)
    local ok, result = pcall(function()
        return game:HttpGet(url)
    end)
    if not ok then
        error("[Cubev4] HTTP request failed: " .. tostring(result), 0)
    end
    return result
end

local runtimeSource = fetch(BASE_URL .. "/runtime.lua")
local compile = loadstring
if type(compile) ~= "function" then
    error("[Cubev4] This environment does not expose loadstring.", 0)
end

local runtimeFunction, compileError = compile(runtimeSource)
if type(runtimeFunction) ~= "function" then
    error("[Cubev4] runtime.lua could not be compiled: " .. tostring(compileError), 0)
end

return runtimeFunction({
    baseUrl = BASE_URL,
    manifestPath = "/data/manifest.json",
})
