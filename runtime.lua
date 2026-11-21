-- Cubev4 client-only morph preview runtime.
-- Loads only the four extracted morph templates and an Animation asset catalogue.
-- This is deliberately NOT a full-place loader and does not invoke server remotes.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local LocalPlayer = Players.LocalPlayer

local Runtime = {}
local MORPH_ORDER = { "M", "F", "FB", "MY" }

local CONTENT_ALIASES = {
    MeshContent = { "MeshId" },
    TextureContent = { "TextureID", "TextureId", "Texture" },
    ImageContent = { "Image" },
    AnimationContent = { "AnimationId" },
    AudioContent = { "SoundId" },
    ShirtTemplateContent = { "ShirtTemplate" },
    PantsTemplateContent = { "PantsTemplate" },
    VideoContent = { "Video" },
    ColorMapContent = { "ColorMap" },
    MetalnessMapContent = { "MetalnessMap" },
    NormalMapContent = { "NormalMap" },
    RoughnessMapContent = { "RoughnessMap" },
    TexturePackContent = { "TexturePack" },
    SkyboxBackContent = { "SkyboxBk" },
    SkyboxDownContent = { "SkyboxDn" },
    SkyboxFrontContent = { "SkyboxFt" },
    SkyboxLeftContent = { "SkyboxLf" },
    SkyboxRightContent = { "SkyboxRt" },
    SkyboxUpContent = { "SkyboxUp" },
    SunTextureContent = { "SunTextureId" },
    MoonTextureContent = { "MoonTextureId" },
}

local function log(message)
    print("[Cubev4] " .. tostring(message))
end

local function warnLog(message)
    warn("[Cubev4] " .. tostring(message))
end

local function fetch(baseUrl, relativePath)
    local url = baseUrl .. "/" .. relativePath:gsub("^/", "")
    local ok, body = pcall(function() return game:HttpGet(url) end)
    if not ok then error("HTTP request failed for " .. url .. ": " .. tostring(body), 0) end
    if type(body) ~= "string" or body == "" then error("Empty response from " .. url, 0) end
    return body
end

local function decodeJson(baseUrl, relativePath)
    local body = fetch(baseUrl, relativePath)
    local ok, value = pcall(function() return HttpService:JSONDecode(body) end)
    if not ok then error("Invalid JSON at " .. relativePath .. ": " .. tostring(value), 0) end
    return value
end

local function decodeValue(value)
    if type(value) ~= "table" then return value end
    local kind = value.__type
    if kind == "Ref" then return { __cubev4Ref = tostring(value.value) } end
    if kind == "EnumItem" then
        local enumType = Enum[value.enumType]
        return enumType and enumType[value.name] or nil
    elseif kind == "Vector3" then
        return Vector3.new(value.x, value.y, value.z)
    elseif kind == "Vector2" then
        return Vector2.new(value.x, value.y)
    elseif kind == "Vector3int16" then
        return Vector3int16.new(value.x, value.y, value.z)
    elseif kind == "Vector2int16" then
        return Vector2int16.new(value.x, value.y)
    elseif kind == "Color3" then
        return Color3.new(value.r, value.g, value.b)
    elseif kind == "CFrame" then
        return CFrame.new(table.unpack(value.components))
    elseif kind == "UDim" then
        return UDim.new(value.scale, value.offset)
    elseif kind == "UDim2" then
        return UDim2.new(value.xScale, value.xOffset, value.yScale, value.yOffset)
    elseif kind == "BrickColor" then
        return BrickColor.new(value.number)
    elseif kind == "NumberRange" then
        return NumberRange.new(value.min, value.max)
    elseif kind == "NumberSequence" then
        local points = {}
        for _, p in ipairs(value.keypoints or {}) do
            points[#points + 1] = NumberSequenceKeypoint.new(p.time, p.value, p.envelope or 0)
        end
        return NumberSequence.new(points)
    elseif kind == "ColorSequence" then
        local points = {}
        for _, p in ipairs(value.keypoints or {}) do
            points[#points + 1] = ColorSequenceKeypoint.new(p.time, Color3.new(p.r, p.g, p.b))
        end
        return ColorSequence.new(points)
    elseif kind == "PhysicalProperties" then
        return PhysicalProperties.new(value.density, value.friction, value.elasticity, value.frictionWeight, value.elasticityWeight)
    elseif kind == "Rect" then
        return Rect.new(value.minX, value.minY, value.maxX, value.maxY)
    elseif kind == "Font" then
        local weight = Enum.FontWeight[value.weight] or Enum.FontWeight.Regular
        local style = Enum.FontStyle[value.style] or Enum.FontStyle.Normal
        return Font.new(value.family, weight, style)
    elseif kind == "Content" then
        return value.uri or value.value or ""
    end
    return nil
end

local function assignProperty(object, propertyName, rawValue, pendingReferences, stats)
    local value = decodeValue(rawValue)
    if type(value) == "table" and value.__cubev4Ref then
        pendingReferences[#pendingReferences + 1] = { object = object, property = propertyName, id = value.__cubev4Ref }
        return
    end
    if value == nil then return end

    local candidates = { propertyName }
    for _, alias in ipairs(CONTENT_ALIASES[propertyName] or {}) do
        candidates[#candidates + 1] = alias
    end
    for _, candidate in ipairs(candidates) do
        local ok = pcall(function() object[candidate] = value end)
        if ok then return end
    end
    stats.propertyFailures += 1
    if #stats.failureSamples < 25 then
        stats.failureSamples[#stats.failureSamples + 1] = object.ClassName .. "." .. propertyName
    end
end

local function createMorphTemplate(baseUrl, entry, templateFolder, stats)
    local payload = decodeJson(baseUrl, "data/" .. entry.file)
    if payload.format ~= "cubev4-morph-v1" then
        error("Unsupported morph payload for " .. tostring(entry.name), 0)
    end

    local objects, pendingParents, pendingReferences = {}, {}, {}
    for index, record in ipairs(payload.instances or {}) do
        local ok, object = pcall(function() return Instance.new(record.class) end)
        if ok and object then
            object.Name = record.name or record.class
            objects[tostring(record.id)] = object
            pendingParents[#pendingParents + 1] = {
                object = object,
                parentId = record.parent and tostring(record.parent) or nil,
            }
            for propertyName, rawValue in pairs(record.properties or {}) do
                if propertyName ~= "Name" and propertyName ~= "Parent" then
                    assignProperty(object, propertyName, rawValue, pendingReferences, stats)
                end
            end
            for attributeName, rawValue in pairs(record.attributes or {}) do
                local attributeValue = decodeValue(rawValue)
                if attributeValue ~= nil and type(attributeValue) ~= "table" then
                    pcall(function() object:SetAttribute(attributeName, attributeValue) end)
                end
            end
            stats.created += 1
        else
            stats.classFailures += 1
            if #stats.failureSamples < 25 then
                stats.failureSamples[#stats.failureSamples + 1] = "Instance.new(" .. tostring(record.class) .. ")"
            end
        end
        if index % 100 == 0 then task.wait() end
    end

    for _, item in ipairs(pendingParents) do
        local parent = item.parentId and objects[item.parentId] or templateFolder
        if parent then
            pcall(function() item.object.Parent = parent end)
        end
    end
    for _, item in ipairs(pendingReferences) do
        local target = objects[item.id]
        if target then
            pcall(function() item.object[item.property] = target end)
        end
    end

    local root = objects[tostring(payload.rootId or "1")]
    if not root then error("Morph root was not created: " .. tostring(entry.name), 0) end
    root.Parent = templateFolder
    return root
end

local function normalizeAnimationId(value)
    if type(value) ~= "string" then return nil end
    local id = value:match("rbxassetid://(%d+)") or value:match("[?&]id=(%d+)") or value:match("(%d+)$")
    return id and ("rbxassetid://" .. id) or nil
end

local function getAnimator(character)
    if not character then return nil end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return nil end
    local animator = humanoid:FindFirstChildOfClass("Animator")
    if not animator then
        animator = Instance.new("Animator")
        animator.Parent = humanoid
    end
    return animator
end

local function createUi(templates, animations, stashFolder)
    local playerGui = LocalPlayer:WaitForChild("PlayerGui")
    local old = playerGui:FindFirstChild("Cubev4LocalPreview")
    if old then old:Destroy() end

    local gui = Instance.new("ScreenGui")
    gui.Name = "Cubev4LocalPreview"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = false
    gui.DisplayOrder = 5000
    gui.Parent = playerGui

    local panel = Instance.new("Frame")
    panel.Name = "Panel"
    panel.Size = UDim2.fromOffset(390, 430)
    panel.Position = UDim2.new(1, -410, 0.5, -215)
    panel.BackgroundColor3 = Color3.fromRGB(24, 27, 34)
    panel.BorderSizePixel = 0
    panel.Parent = gui
    Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 10)

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -20, 0, 34)
    title.Position = UDim2.fromOffset(10, 8)
    title.BackgroundTransparency = 1
    title.Text = "Cubev4 • Local Morph Preview"
    title.TextColor3 = Color3.fromRGB(245, 247, 250)
    title.TextSize = 17
    title.Font = Enum.Font.GothamBold
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = panel

    local status = Instance.new("TextLabel")
    status.Name = "Status"
    status.Size = UDim2.new(1, -20, 0, 28)
    status.Position = UDim2.fromOffset(10, 42)
    status.BackgroundTransparency = 1
    status.Text = "Choose a morph. Changes are local to your client."
    status.TextColor3 = Color3.fromRGB(180, 190, 204)
    status.TextSize = 12
    status.TextWrapped = true
    status.Font = Enum.Font.Gotham
    status.TextXAlignment = Enum.TextXAlignment.Left
    status.Parent = panel

    local function setStatus(text)
        status.Text = text
    end

    local buttonRow = Instance.new("Frame")
    buttonRow.BackgroundTransparency = 1
    buttonRow.Position = UDim2.fromOffset(10, 76)
    buttonRow.Size = UDim2.new(1, -20, 0, 42)
    buttonRow.Parent = panel
    local rowLayout = Instance.new("UIListLayout")
    rowLayout.FillDirection = Enum.FillDirection.Horizontal
    rowLayout.Padding = UDim.new(0, 6)
    rowLayout.SortOrder = Enum.SortOrder.LayoutOrder
    rowLayout.Parent = buttonRow

    local function button(parent, text, width)
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(0, width, 1, 0)
        b.BackgroundColor3 = Color3.fromRGB(53, 64, 82)
        b.BorderSizePixel = 0
        b.Text = text
        b.TextColor3 = Color3.new(1, 1, 1)
        b.TextSize = 13
        b.Font = Enum.Font.GothamSemibold
        b.AutoButtonColor = true
        b.Parent = parent
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
        return b
    end

    local morphButtons = {}
    for _, morphName in ipairs(MORPH_ORDER) do
        if templates[morphName] then
            morphButtons[morphName] = button(buttonRow, morphName, 58)
        end
    end
    local resetButton = button(buttonRow, "Reset", 72)

    local animTitle = Instance.new("TextLabel")
    animTitle.Size = UDim2.new(1, -20, 0, 24)
    animTitle.Position = UDim2.fromOffset(10, 126)
    animTitle.BackgroundTransparency = 1
    animTitle.Text = "Animation catalogue (asset access required)"
    animTitle.TextColor3 = Color3.fromRGB(220, 225, 234)
    animTitle.TextSize = 12
    animTitle.Font = Enum.Font.GothamSemibold
    animTitle.TextXAlignment = Enum.TextXAlignment.Left
    animTitle.Parent = panel

    local search = Instance.new("TextBox")
    search.Size = UDim2.new(1, -20, 0, 30)
    search.Position = UDim2.fromOffset(10, 152)
    search.BackgroundColor3 = Color3.fromRGB(36, 42, 53)
    search.BorderSizePixel = 0
    search.PlaceholderText = "Filter animations by name or path..."
    search.Text = ""
    search.TextColor3 = Color3.new(1, 1, 1)
    search.PlaceholderColor3 = Color3.fromRGB(145, 153, 166)
    search.TextSize = 12
    search.Font = Enum.Font.Gotham
    search.ClearTextOnFocus = false
    search.Parent = panel
    Instance.new("UICorner", search).CornerRadius = UDim.new(0, 6)

    local list = Instance.new("ScrollingFrame")
    list.Name = "AnimationList"
    list.Size = UDim2.new(1, -20, 0, 180)
    list.Position = UDim2.fromOffset(10, 190)
    list.BackgroundColor3 = Color3.fromRGB(31, 36, 46)
    list.BorderSizePixel = 0
    list.ScrollBarThickness = 6
    list.CanvasSize = UDim2.new()
    list.AutomaticCanvasSize = Enum.AutomaticSize.Y
    list.Parent = panel
    Instance.new("UICorner", list).CornerRadius = UDim.new(0, 6)
    local listLayout = Instance.new("UIListLayout")
    listLayout.Padding = UDim.new(0, 3)
    listLayout.SortOrder = Enum.SortOrder.LayoutOrder
    listLayout.Parent = list
    local listPadding = Instance.new("UIPadding")
    listPadding.PaddingTop = UDim.new(0, 4)
    listPadding.PaddingBottom = UDim.new(0, 4)
    listPadding.PaddingLeft = UDim.new(0, 4)
    listPadding.PaddingRight = UDim.new(0, 4)
    listPadding.Parent = list

    local stopAnimation = button(panel, "Stop animation", 130)
    stopAnimation.Position = UDim2.fromOffset(10, 382)
    stopAnimation.Size = UDim2.fromOffset(130, 34)

    local hint = Instance.new("TextLabel")
    hint.Position = UDim2.fromOffset(150, 382)
    hint.Size = UDim2.new(1, -160, 0, 34)
    hint.BackgroundTransparency = 1
    hint.Text = "If an asset is private or rig-incompatible, Roblox may refuse playback."
    hint.TextColor3 = Color3.fromRGB(150, 160, 176)
    hint.TextWrapped = true
    hint.TextSize = 10
    hint.Font = Enum.Font.Gotham
    hint.Parent = panel

    local currentTrack = nil
    local function stopTrack()
        if currentTrack then
            pcall(function() currentTrack:Stop(0.15); currentTrack:Destroy() end)
            currentTrack = nil
        end
    end

    local function playAnimation(entry)
        stopTrack()
        local character = LocalPlayer.Character
        local animator = getAnimator(character)
        if not animator then
            setStatus("Your character has no Humanoid yet.")
            return
        end
        local animation = Instance.new("Animation")
        animation.AnimationId = normalizeAnimationId(entry.id) or entry.id
        local ok, trackOrError = pcall(function() return animator:LoadAnimation(animation) end)
        if not ok then
            animation:Destroy()
            setStatus("Could not load animation: " .. tostring(trackOrError))
            return
        end
        currentTrack = trackOrError
        local played, playError = pcall(function() currentTrack:Play(0.15) end)
        if not played then
            stopTrack()
            setStatus("Animation playback failed: " .. tostring(playError))
            return
        end
        setStatus("Playing: " .. tostring(entry.name))
    end

    local function rebuildAnimationList()
        for _, child in ipairs(list:GetChildren()) do
            if child:IsA("TextButton") then child:Destroy() end
        end
        local query = string.lower(search.Text or "")
        local shown = 0
        for _, entry in ipairs(animations) do
            local haystack = string.lower(tostring(entry.name) .. " " .. tostring(entry.path))
            if query == "" or string.find(haystack, query, 1, true) then
                shown += 1
                local b = Instance.new("TextButton")
                b.Size = UDim2.new(1, -8, 0, 28)
                b.BackgroundColor3 = Color3.fromRGB(54, 65, 82)
                b.BorderSizePixel = 0
                b.Text = string.sub(tostring(entry.name) .. "  •  " .. tostring(entry.id), 1, 75)
                b.TextColor3 = Color3.fromRGB(240, 243, 248)
                b.TextSize = 11
                b.Font = Enum.Font.Gotham
                b.TextXAlignment = Enum.TextXAlignment.Left
                b.Parent = list
                Instance.new("UICorner", b).CornerRadius = UDim.new(0, 4)
                b.Activated:Connect(function() playAnimation(entry) end)
            end
        end
        if shown == 0 then
            local empty = Instance.new("TextLabel")
            empty.Size = UDim2.new(1, -8, 0, 28)
            empty.BackgroundTransparency = 1
            empty.Text = "No matching animations"
            empty.TextColor3 = Color3.fromRGB(170, 178, 190)
            empty.TextSize = 11
            empty.Parent = list
        end
    end
    search:GetPropertyChangedSignal("Text"):Connect(rebuildAnimationList)
    rebuildAnimationList()

    return {
        morphButtons = morphButtons,
        resetButton = resetButton,
        setStatus = setStatus,
        stopTrack = stopTrack,
    }
end

function Runtime.run(options)
    options = options or {}
    local baseUrl = assert(options.baseUrl, "baseUrl is required")
    if not LocalPlayer then error("LocalPlayer is unavailable; run this from a client context.", 0) end

    log("Downloading focused morph manifest...")
    local manifest = decodeJson(baseUrl, "data/manifest.json")
    if manifest.format ~= "cubev4-morph-preview-v1" then
        error("Wrong data format. Replace export_place.luau, rerun build_place.bat, and upload the new data folder.", 0)
    end

    local playerGui = LocalPlayer:WaitForChild("PlayerGui")
    local oldFolder = playerGui:FindFirstChild("Cubev4LocalTemplates")
    if oldFolder then oldFolder:Destroy() end
    local templateFolder = Instance.new("Folder")
    templateFolder.Name = "Cubev4LocalTemplates"
    templateFolder.Parent = playerGui

    local stats = { created = 0, classFailures = 0, propertyFailures = 0, failureSamples = {} }
    local templates = {}
    for index, entry in ipairs(manifest.morphs or {}) do
        log(string.format("Loading morph template %d/%d: %s", index, #manifest.morphs, entry.name))
        local template = createMorphTemplate(baseUrl, entry, templateFolder, stats)
        templates[entry.name] = template
        task.wait()
    end

    local animationPayload = decodeJson(baseUrl, "data/" .. (manifest.animationsFile or "animations.json"))
    local animations = animationPayload.animations or {}
    local storedFolder = playerGui:FindFirstChild("Cubev4StoredAppearance")
    if storedFolder then storedFolder:Destroy() end
    storedFolder = Instance.new("Folder")
    storedFolder.Name = "Cubev4StoredAppearance"
    storedFolder.Parent = playerGui

    local state = { character = nil, asset = nil, transparencies = {}, movedClothing = {}, originalCharacter = nil }
    local function restoreMorph()
        if state.asset then
            pcall(function() state.asset:Destroy() end)
            state.asset = nil
        end
        for part, transparency in pairs(state.transparencies) do
            if part and part.Parent then pcall(function() part.Transparency = transparency end) end
        end
        table.clear(state.transparencies)
        for _, item in ipairs(state.movedClothing) do
            if item and item.Parent == storedFolder and state.character and state.character.Parent then
                pcall(function() item.Parent = state.character end)
            end
        end
        table.clear(state.movedClothing)
    end

    local function applyMorph(morphName)
        local template = templates[morphName]
        if not template then
            return false, "Morph was not included in the export: " .. tostring(morphName)
        end
        local character = LocalPlayer.Character
        if not character then return false, "Your character has not spawned." end
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        if not humanoid then return false, "Your character has no Humanoid." end
        if not character:FindFirstChild("Torso") then
            return false, "This morph rig expects an R6 character with a Torso."
        end

        restoreMorph()
        state.character = character
        state.originalCharacter = character

        for _, item in ipairs(character:GetChildren()) do
            if item:IsA("Clothing") or item:IsA("CharacterMesh") or item:IsA("ShirtGraphic") then
                table.insert(state.movedClothing, item)
                item.Parent = storedFolder
            end
        end

        local clone = template:Clone()
        clone.Name = "Asset"
        local attached = 0
        for _, morphPart in ipairs(clone:GetChildren()) do
            local limb = character:FindFirstChild(morphPart.Name)
            if limb and limb:IsA("BasePart") and morphPart:IsA("BasePart") then
                if state.transparencies[limb] == nil then
                    state.transparencies[limb] = limb.Transparency
                end
                limb.Transparency = 1
                morphPart.Anchored = false
                morphPart.CanCollide = false
                morphPart.Massless = true
                for _, component in ipairs(morphPart:GetDescendants()) do
                    if component:IsA("BasePart") then
                        component.Anchored = false
                        component.CanCollide = false
                        component.Massless = true
                        local excluded = component.Name == "darker" or component.Name == "darkera"
                            or component.Name == "Cube.004" or component.Name == "Cube.005"
                            or string.find(component.Name, "sticky_") or string.find(component.Name, "Mball.")
                        if not excluded then
                            pcall(function() component.Color = limb.Color end)
                        end
                    end
                    if morphName == "M" and component:IsA("Bone") and string.find(component.Name, "droop") then
                        pcall(function() component.CFrame = CFrame.Angles(math.pi / 2, 0, 0) end)
                    end
                end
                local weld = Instance.new("Motor6D")
                weld.Name = "Cubev4MorphJoint"
                weld.Part0 = limb
                weld.Part1 = morphPart
                weld.Parent = morphPart
                attached += 1
            end
        end

        if attached == 0 then
            clone:Destroy()
            restoreMorph()
            return false, "No morph body parts matched. Check that the avatar is R6 and the model exported correctly."
        end
        clone.Parent = character
        state.asset = clone
        return true, string.format("Applied %s locally (%d body attachments).", morphName, attached)
    end

    local ui = createUi(templates, animations, storedFolder)
    for morphName, button in pairs(ui.morphButtons) do
        button.Activated:Connect(function()
            local ok, message = applyMorph(morphName)
            ui.setStatus(message)
            if not ok then warnLog(message) end
        end)
    end
    ui.resetButton.Activated:Connect(function()
        restoreMorph()
        ui.setStatus("Local morph removed; original clothing and limb visibility restored.")
    end)

    LocalPlayer.CharacterAdded:Connect(function(character)
        restoreMorph()
        state.character = character
        ui.setStatus("Character respawned. Choose a morph again.")
    end)

    log(string.format("Ready. Morph templates: %d | animation IDs: %d | Instances created: %d", #manifest.morphs, #animations, stats.created))
    log(string.format("Property assignment failures: %d | Class failures: %d", stats.propertyFailures, stats.classFailures))
    for _, sample in ipairs(stats.failureSamples) do warnLog("Skipped/failed: " .. sample) end
    if #manifest.morphs < 4 then warnLog("One or more expected morph templates were missing from the RBXL export.") end
    if stats.propertyFailures > 0 then warnLog("Some asset/property fields were not writable in this client runtime; mesh rendering may be incomplete.") end

    return {
        templates = templates,
        animationCount = #animations,
        stats = stats,
        restore = restoreMorph,
    }
end

return function(options)
    return Runtime.run(options)
end
