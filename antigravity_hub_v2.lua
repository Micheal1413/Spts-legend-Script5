-- cleanup old GUIs
for _, v in ipairs(game:GetService("CoreGui"):GetChildren()) do
    if v.Name == "AntigravityHubGui" or v.Name == "LineShotUI" or v.Name == "CombinedHubGui" then v:Destroy() end
end
for _, v in ipairs(game.Players.LocalPlayer.PlayerGui:GetChildren()) do
    if v.Name == "AntigravityHubGui" or v.Name == "LineShotUI" or v.Name == "CombinedHubGui" then v:Destroy() end
end

task.wait(0.3)

local Players      = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local StarterGui   = game:GetService("StarterGui")
local CG           = game:GetService("CoreGui")
local Lighting     = game:GetService("Lighting")
local VirtualUser  = game:GetService("VirtualUser")
local LP           = Players.LocalPlayer
local PG           = LP:WaitForChild("PlayerGui")
local Camera       = workspace.CurrentCamera

local RemoteEvents     = game.ReplicatedStorage.RemoteEvents
local RefreshCharacter = RemoteEvents.RefreshCharacter
local Loaded           = RemoteEvents.Loaded
local UseSkill         = RemoteEvents.UseSkill

_G.ActiveTrainer      = nil   -- "BT" | "FS" | "PS" | nil
_G.AutoRespawnEnabled = true
_G.ARTeleportBack     = true
_G.AutoQuestEnabled   = true
if _G.hubKillFlag then _G.hubKillFlag() end
local hubAlive = true
_G.hubKillFlag = function() hubAlive = false end

local lastDeathCFrame = nil
local dtDivisor       = 20

-- SUFFIX TABLE
local suffixes = {
    {"Qid",1e48},{"Qad",1e45},
    {"Td", 1e42},{"DD", 1e39},{"Ud", 1e36},
    {"Dc", 1e33},{"No", 1e30},{"Oc", 1e27},{"Sp", 1e24},
    {"Sx", 1e21},{"Qi", 1e18},{"Qa", 1e15},
    {"T",  1e12},{"B",  1e9}, {"M",  1e6}, {"K",  1e3},
}

local function parseName(name)
    for _, pair in ipairs(suffixes) do
        local n = name:match("^(%d+%.?%d*)" .. pair[1] .. "$")
        if n then return tonumber(n) * pair[2] end
    end
    return tonumber(name)
end

local function fmtNum(n)
    if not n or n <= 0 then return "0" end
    for i = 1, #suffixes do
        if n >= suffixes[i][2] then
            return string.format("%.3g%s", n / suffixes[i][2], suffixes[i][1])
        end
    end
    return tostring(math.floor(n))
end

local function fmtTime(secs)
    if secs <= 0 or secs ~= secs then return "now" end
    if secs > 86400*30 then return ">30d" end
    if secs > 86400 then return string.format("%.1fd", secs/86400) end
    if secs > 3600  then return string.format("%.1fh", secs/3600) end
    if secs > 60    then return string.format("%.1fm", secs/60) end
    return string.format("%.0fs", secs)
end

-- FUSION
local fusionTiers = {
    {name="Yeti",    req=1e18},
    {name="Werewolf",req=1e24},
    {name="Gryphon", req=1e30},
    {name="Phoenix", req=1e38},
    {name="Reaper",  req=1e44},
    {name="Omega",   req=1e48},
    {name="Zenith",  req=1e52},
    {name="Paragon", req=5e54},
}
local fusionSamples = {}
local FUSION_WINDOW = 300
local lastFusionTier = tonumber(LP:GetAttribute("FusionTier") or 0)

local function recordFusion(tp)
    local now = tick()
    -- wipe samples on rebirth so stale pre-rebirth TP doesnt corrupt rate/ETA
    local curTier = tonumber(LP:GetAttribute("FusionTier") or 0)
    if curTier ~= lastFusionTier then
        fusionSamples = {}
        lastFusionTier = curTier
    end
    table.insert(fusionSamples, {t=now, v=tp})
    while fusionSamples[1] and (now-fusionSamples[1].t) > FUSION_WINDOW do table.remove(fusionSamples,1) end
end

local function getFusionRate()
    if #fusionSamples < 2 then return 0 end
    local dt = fusionSamples[#fusionSamples].t - fusionSamples[1].t
    if dt < 1 then return 0 end
    return math.max(0, (fusionSamples[#fusionSamples].v - fusionSamples[1].v) / dt)
end

local function fmtETALong(secs)
    if secs <= 0 or secs ~= secs then return "Ready! ✅" end
    if secs == math.huge then return "---" end
    local d=math.floor(secs/86400); local h=math.floor((secs%86400)/3600); local m=math.floor((secs%3600)/60)
    if d > 0 then return string.format("~%dd %dh", d, h) end
    if h > 0 then return string.format("~%dh %dm", h, m) end
    if m > 0 then return string.format("~%dm", m) end
    local s=math.floor(secs%60); return string.format("~%dm %ds",m,s)
end

local function getNextFusionTier()
    local tier = tonumber(LP:GetAttribute("FusionTier") or 0)
    return fusionTiers[tier + 1]
end

-- LOAD TRAINING AREAS
local hitboxes = game.Workspace:WaitForChild("Main"):WaitForChild("TrainingAreasHitBoxes")

local function loadAreas(folderName)
    local areas = {}
    local folder = hitboxes:WaitForChild(folderName)
    for _, part in ipairs(folder:GetChildren()) do
        if not part:IsA("BasePart") then continue end
        local req = tonumber(part:GetAttribute("Requirement")) or parseName(part.Name) or 0
        table.insert(areas, {
            part  = part,
            req   = req,
            multi = tonumber(part:GetAttribute("Multiplier")) or 1,
            pos   = part.Position,
            cf    = part.CFrame,
            halfY = part.Size.Y / 2,
            name  = part.Name,
        })
    end
    table.sort(areas, function(a,b) return a.req < b.req end)
    warn("[AG] Loaded " .. #areas .. " " .. folderName .. " areas")
    return areas
end

local btAreas = loadAreas("BT")
local fsAreas = loadAreas("FS")
local psAreas = loadAreas("PS")

-- maps trainer key -> area list + stat attribute
local trainerConfig = {
    BT = {areas=btAreas, stat="BodyToughness",   multiStat="BodyToughnessMultiplier",   color=Color3.fromRGB(255,140,50)},
    FS = {areas=fsAreas, stat="FistStrength",     multiStat="FistStrengthMultiplier",    color=Color3.fromRGB(100,180,255)},
    PS = {areas=psAreas, stat="PsychicPower",     multiStat="PsychicPowerMultiplier",    color=Color3.fromRGB(200,100,255)},
}

local function getAreaLandCFrame(a)
    -- Land just inside the top surface of the part using local space.
    -- halfY - 1 keeps us inside the hitbox bounds (avoids the +3 overshoot bug).
    return a.part.CFrame * CFrame.new(0, a.halfY - 1, 0)
end

-- Returns true if the player is inside the training area part (proper OBB check)
local function isInsideArea(pos, a)
    local localPos = a.part.CFrame:PointToObjectSpace(pos)
    local half = a.part.Size / 2
    return math.abs(localPos.X) <= half.X
        and math.abs(localPos.Y) <= half.Y
        and math.abs(localPos.Z) <= half.Z
end

local function getBestArea(areas, statVal)
    local best = nil
    for _, a in ipairs(areas) do
        if statVal >= a.req / dtDivisor then best = a end
    end
    return best
end

local function getNextAreaFrom(areas, current)
    if not current then return areas[1] end
    for i, a in ipairs(areas) do
        if a == current then return areas[i+1] end
    end
    return nil
end

-- NUKER CONFIG
local burstSpeed     = 0.2
local hoverHeight    = 15
local behindDist     = 30
local maxClusterDist = 200
local nukerRunning   = false
local teleportMode   = true
local antiIdle       = true
local autoSkipWeak   = true
local priorityMode   = true

local tokenPriority  = {"Phantom","Robot","Sath","WereWolf","Mafia","Thug","Noob"}
local tokenValues    = {Phantom=25e12,Robot=1e12,Sath=1e6,WereWolf=500000,Mafia=200000,Thug=10000,Noob=1000}
local trackable      = {Noob=true,Thug=true,Mafia=true,WereWolf=true,Robot=true,Sath=true,Phantom=true}
local enabledTargets = {Noob=true,Thug=true,Mafia=true,WereWolf=true,Robot=false,Sath=true,Phantom=true}
-- SETTINGS PERSISTENCE
local SETTINGS_FILE = "ag_hub_settings.json"
local function lB(s, key, def)
    local v = s:match('"' .. key .. '":(%a+)')
    if v == "true" then return true elseif v == "false" then return false end
    return def
end
local function lS(s, key)
    return s:match('"' .. key .. '":"([^"]+)"')
end
local _sv = nil
local _svOk, _svErr = pcall(function() if readfile then local r = readfile(SETTINGS_FILE) if r and #r > 2 then _sv = r end end end)
if not _svOk then warn('[Settings] Load error: ' .. tostring(_svErr)) end
if _sv then warn('[Settings] Loaded from disk OK') else warn('[Settings] No save file, using defaults') end
if _sv then
    _G.ActiveTrainer      = lS(_sv, "activeTrainer")
    _G.AutoRespawnEnabled = lB(_sv, "autoRespawn",    true)
    _G.ARTeleportBack     = lB(_sv, "arTeleportBack", true)
    _G.AutoQuestEnabled   = lB(_sv, "autoQuest",      true)
    enabledTargets.Noob     = lB(_sv, "Noob",     true)
    enabledTargets.Thug     = lB(_sv, "Thug",     true)
    enabledTargets.Mafia    = lB(_sv, "Mafia",    true)
    enabledTargets.WereWolf = lB(_sv, "WereWolf", true)
    enabledTargets.Robot    = lB(_sv, "Robot",    false)
    enabledTargets.Sath     = lB(_sv, "Sath",     true)
    enabledTargets.Phantom  = lB(_sv, "Phantom",  true)
end
local teleportMode = (_sv and lB(_sv, "teleportMode", true)) or true
local antiIdle     = (_sv and lB(_sv, "antiIdle",     true)) or true
local autoSkipWeak = (_sv and lB(_sv, "autoSkipWeak", true)) or true
local priorityMode = (_sv and lB(_sv, "priorityMode", true)) or true
local function saveSettings()
    local at = _G.ActiveTrainer and ('"' .. _G.ActiveTrainer .. '"') or "null"
    local et = enabledTargets
    local json = string.format(
        '{"activeTrainer":%s,"autoRespawn":%s,"arTeleportBack":%s,"autoQuest":%s,"teleportMode":%s,"antiIdle":%s,"autoSkipWeak":%s,"priorityMode":%s,"Noob":%s,"Thug":%s,"Mafia":%s,"WereWolf":%s,"Robot":%s,"Sath":%s,"Phantom":%s}',
        at,
        tostring(_G.AutoRespawnEnabled),
        tostring(_G.ARTeleportBack),
        tostring(_G.AutoQuestEnabled),
        tostring(teleportMode),
        tostring(antiIdle),
        tostring(autoSkipWeak),
        tostring(priorityMode),
        tostring(et.Noob),
        tostring(et.Thug),
        tostring(et.Mafia),
        tostring(et.WereWolf),
        tostring(et.Robot),
        tostring(et.Sath),
        tostring(et.Phantom)
    )
    local ok, err = pcall(function() if writefile then writefile(SETTINGS_FILE, json) end end)
    if not ok then warn("[Settings] Save failed: " .. tostring(err)) end
end

local character = LP.Character or LP.CharacterAdded:Wait()
local hrp       = character:WaitForChild("HumanoidRootPart")
LP.CharacterAdded:Connect(function(c) character=c; hrp=c:WaitForChild("HumanoidRootPart") end)

LP.Idled:Connect(function() if not antiIdle then return end VirtualUser:CaptureController() VirtualUser:ClickButton2(Vector2.new()) end)
task.spawn(function() while task.wait(60) do if antiIdle then VirtualUser:CaptureController() VirtualUser:ClickButton2(Vector2.new()) end end end)

local function getSphereRadius()
    local fs = LP:GetAttribute("FistStrength") or 0
    if fs>=1e21 then return 15 elseif fs>=1e18 then return 12 elseif fs>=1e15 then return 9
    elseif fs>=1e12 then return 7 elseif fs>=1e9 then return 5 elseif fs>=1e6 then return 3.5
    elseif fs>=1e4 then return 2.5 elseif fs>=1e3 then return 2 else return 1.5 end
end

local function getRootPart(m) return m:FindFirstChild("HumanoidRootPart") or m:FindFirstChild("Torso") end
local function getPos(t) if t and t.hrp and t.hrp.Parent then return t.hrp.Position end return nil end
local function distToLine(c,d,P) local v=P-c return (v-d*v:Dot(d)).Magnitude end

local function fitLine(group)
    local cx,cy,cz=0,0,0; local valid={}
    for _,t in ipairs(group) do local p=getPos(t) if p then cx+=p.X;cy+=p.Y;cz+=p.Z;table.insert(valid,p) end end
    local vn=#valid
    if vn==0 then return Vector3.new(0,0,0),Vector3.new(1,0,0) end
    cx/=vn;cy/=vn;cz/=vn; local centroid=Vector3.new(cx,cy,cz)
    if vn==1 then return centroid,Vector3.new(1,0,0) end
    local sxx,sxy,sxz,syy,syz,szz=0,0,0,0,0,0
    for _,p in ipairs(valid) do local dx,dy,dz=p.X-cx,p.Y-cy,p.Z-cz sxx+=dx*dx;sxy+=dx*dy;sxz+=dx*dz;syy+=dy*dy;syz+=dy*dz;szz+=dz*dz end
    local vx,vy,vz=1,0,0
    for _=1,32 do local nx=sxx*vx+sxy*vy+sxz*vz;local ny=sxy*vx+syy*vy+syz*vz;local nz=sxz*vx+syz*vy+szz*vz;local mag=math.sqrt(nx*nx+ny*ny+nz*nz) if mag<1e-10 then break end vx,vy,vz=nx/mag,ny/mag,nz/mag end
    local mag=math.sqrt(vx*vx+vy*vy+vz*vz)
    if mag<1e-10 then return centroid,Vector3.new(1,0,0) end
    return centroid,Vector3.new(vx/mag,vy/mag,vz/mag)
end

local function findBestLine(targets,radius)
    local alive={}; for _,t in ipairs(targets) do if getPos(t) then table.insert(alive,t) end end
    if #alive==0 then return nil end
    if #alive==1 then local pos=getPos(alive[1]) return pos+Vector3.new(0,hoverHeight,-behindDist),Vector3.new(0,0,1),0,pos,1 end
    local bestOrigin,bestDir,bestMaxDist,bestCentroid; local bestHits=-1
    for _,seed in ipairs(alive) do
        local seedPos=getPos(seed); if not seedPos then continue end
        local cluster={}; for _,t in ipairs(alive) do local p=getPos(t) if p and (p-seedPos).Magnitude<=maxClusterDist then table.insert(cluster,t) end end
        if #cluster<2 then continue end
        local centroid,dir=fitLine(cluster); local hits,maxDist=0,0
        for _,t in ipairs(alive) do local p=getPos(t) if p then local d=distToLine(centroid,dir,p) if d<=radius then hits+=1 end if d>maxDist then maxDist=d end end end
        if hits>bestHits or (hits==bestHits and maxDist<(bestMaxDist or math.huge)) then bestHits=hits;bestMaxDist=maxDist;bestDir=dir;bestCentroid=centroid;bestOrigin=centroid-dir*behindDist+Vector3.new(0,hoverHeight,0) end
    end
    if not bestCentroid then
        local centroid,dir=fitLine(alive); local maxDist=0
        for _,t in ipairs(alive) do local p=getPos(t) if p then local d=distToLine(centroid,dir,p) if d>maxDist then maxDist=d end end end
        bestOrigin=centroid-dir*behindDist+Vector3.new(0,hoverHeight,0);bestDir=dir;bestMaxDist=maxDist;bestCentroid=centroid;bestHits=1
    end
    return bestOrigin,bestDir,bestMaxDist,bestCentroid,bestHits
end

local cachedTargets={};local registeredModels={};local toggleButtons={}

local function isAliveEntry(t) return t.model and t.model.Parent and t.hrp and t.hrp.Parent and t.hum and t.hum.Parent and t.hum.Health>0 end

local function getAlive()
    local all={}; for _,t in ipairs(cachedTargets) do if isAliveEntry(t) and enabledTargets[t.name] then table.insert(all,t) end end
    if not priorityMode or #all==0 then return all end
    for _,name in ipairs(tokenPriority) do
        if not enabledTargets[name] then continue end
        local subset={}; for _,t in ipairs(all) do if t.name==name then table.insert(subset,t) end end
        if #subset>0 then return subset end
    end
    return all
end

local function pruneCache()
    local fresh,freshSet={},{}
    for _,t in ipairs(cachedTargets) do
        if t.model and t.model.Parent and not freshSet[t.model] then table.insert(fresh,t);freshSet[t.model]=true else registeredModels[t.model]=nil end
    end
    cachedTargets=fresh
end

local function refreshToggleColor(name)
    local btn=toggleButtons[name]; if not btn then return end
    local on=enabledTargets[name]
    TweenService:Create(btn,TweenInfo.new(0.15),{BackgroundColor3=on and Color3.fromRGB(40,160,80) or Color3.fromRGB(55,55,55)}):Play()
    btn.TextColor3=on and Color3.fromRGB(255,255,255) or Color3.fromRGB(110,110,110)
end

local function tryRegisterModel(model)
    if not (model:IsA("Model") and trackable[model.Name]) then return end
    if registeredModels[model] then return end
    local rp=getRootPart(model); local hum=model:FindFirstChildOfClass("Humanoid")
    if not rp or not hum then return end
    registeredModels[model]=true
    local entry={hrp=rp,hum=hum,model=model,name=model.Name,hitCount=0}
    table.insert(cachedTargets,entry)
    local lastHealth=hum.Health
    hum.HealthChanged:Connect(function(newHealth)
        if newHealth<lastHealth then entry.hitCount+=1 end
        lastHealth=newHealth
        if newHealth<=0 and autoSkipWeak and entry.hitCount<=3 then enabledTargets[model.Name]=false refreshToggleColor(model.Name) end
    end)
end

local function buildCache() pruneCache(); for _,obj in ipairs(workspace:GetDescendants()) do tryRegisterModel(obj) end end

workspace.DescendantAdded:Connect(function(child)
    if not (child:IsA("Model") and trackable[child.Name]) then return end
    if registeredModels[child] then return end
    task.spawn(function()
        for _=1,5 do task.wait(1) if not child.Parent then return end if getRootPart(child) and child:FindFirstChildOfClass("Humanoid") then tryRegisterModel(child) return end end
        local rp=child:FindFirstChild("HumanoidRootPart") or child:FindFirstChild("Torso")
        local hum=child:FindFirstChildOfClass("Humanoid") or child:WaitForChild("Humanoid",3)
        if rp and hum then tryRegisterModel(child) end
    end)
end)

buildCache()
task.spawn(function() while true do task.wait(10) buildCache() end end)

-- RESPAWN / CAMERA
local function restoreUI()
    local pg=LP.PlayerGui
    for _,name in ipairs({"MainGui","QuestsGui","WeightGui","SkillCooldowns"}) do local gui=pg:FindFirstChild(name) if gui then gui.Enabled=true end end
    local ig=pg:FindFirstChild("IntroGui"); if ig then ig.Enabled=false end
    StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack,true)
    TweenService:Create(Lighting.Blur,TweenInfo.new(0.4),{Size=0}):Play()
end

local function fixCamera(char)
    task.spawn(function()
        local hum=char:WaitForChild("Humanoid",10)
        if not hum then return end
        local deadline=tick()+3
        while tick()<deadline do
            task.wait(0.05)
            Camera.CameraType=Enum.CameraType.Custom
            Camera.CameraSubject=hum
            if Camera.CameraType==Enum.CameraType.Custom and Camera.CameraSubject==hum then break end
        end
    end)
end

local function hookCharacter(char)
    local hum=char:WaitForChild("Humanoid",10); if not hum then return end
    hum.Died:Connect(function()
        if not _G.AutoRespawnEnabled then return end
        local crp=char:FindFirstChild("HumanoidRootPart"); if crp then lastDeathCFrame=crp.CFrame end
        task.wait(0.05); RefreshCharacter:FireServer()
        local newChar=LP.CharacterAdded:Wait()
        local newHum=newChar:WaitForChild("Humanoid",5)
        local newCRP=newChar:WaitForChild("HumanoidRootPart",5)
        if newHum then Camera.CameraType=Enum.CameraType.Custom; Camera.CameraSubject=newHum end
        task.wait(0.2)
        Loaded:FireServer(); task.wait(0.05)
        restoreUI()
        if _G.ARTeleportBack and newCRP then
            task.wait(0.05)
            if _G.activeTrainArea then
                if not isInsideArea(newCRP.Position, _G.activeTrainArea) then
                    newCRP.CFrame = getAreaLandCFrame(_G.activeTrainArea)
                end
            elseif lastDeathCFrame then
                newCRP.CFrame=lastDeathCFrame*CFrame.new(0,3,0)
            end
            if newHum then Camera.CameraType=Enum.CameraType.Custom; Camera.CameraSubject=newHum end
        end
        fixCamera(newChar)
        warn("[AutoRespawn] Done")
    end)
end

if LP.Character then
    hookCharacter(LP.Character)
    fixCamera(LP.Character)
    -- fire join-time loaded sequence so intro/blur clears without clicking
    task.spawn(function()
        task.wait(0.3)
        pcall(function() Loaded:FireServer() end)
        task.wait(0.05)
        restoreUI()
        warn("[AutoRespawn] Join-time load fired")
    end)
end
LP.CharacterAdded:Connect(function(char) hookCharacter(char) fixCamera(char) end)

-- GUI
local sg=Instance.new("ScreenGui"); sg.Name="CombinedHubGui"; sg.ResetOnSpawn=false
pcall(function() sg.Parent=CG end); if not sg.Parent then sg.Parent=PG end

local frameW=310; local pad=10; local iw=frameW-pad*2

local mainFrame=Instance.new("Frame")
mainFrame.Size=UDim2.new(0,frameW,0,510); mainFrame.Position=UDim2.new(0.05,0,0.05,0)
mainFrame.BackgroundColor3=Color3.fromRGB(12,12,18); mainFrame.BorderSizePixel=0
mainFrame.Active=true; mainFrame.Draggable=true; mainFrame.Parent=sg
Instance.new("UICorner",mainFrame).CornerRadius=UDim.new(0,12)
local mainStroke=Instance.new("UIStroke",mainFrame); mainStroke.Color=Color3.fromRGB(100,75,150); mainStroke.Thickness=1.5

local titleBar=Instance.new("Frame")
titleBar.Size=UDim2.new(1,0,0,36); titleBar.BackgroundColor3=Color3.fromRGB(20,16,30)
titleBar.BorderSizePixel=0; titleBar.Parent=mainFrame
Instance.new("UICorner",titleBar).CornerRadius=UDim.new(0,12)
local titleLbl=Instance.new("TextLabel")
titleLbl.Size=UDim2.new(1,-12,1,0); titleLbl.Position=UDim2.new(0,12,0,0); titleLbl.BackgroundTransparency=1
titleLbl.Font=Enum.Font.GothamBold; titleLbl.TextSize=13; titleLbl.TextColor3=Color3.fromRGB(220,210,255)
titleLbl.Text="🌌 Antigravity Hub  ⚡ Line Shot"; titleLbl.TextXAlignment=Enum.TextXAlignment.Left; titleLbl.Parent=titleBar

local tabRow=Instance.new("Frame")
tabRow.Size=UDim2.new(1,-16,0,28); tabRow.Position=UDim2.new(0,8,0,40)
tabRow.BackgroundTransparency=1; tabRow.Parent=mainFrame
local tabLayout=Instance.new("UIListLayout"); tabLayout.FillDirection=Enum.FillDirection.Horizontal; tabLayout.Padding=UDim.new(0,6); tabLayout.Parent=tabRow

local function mkTab(txt)
    local b=Instance.new("TextButton"); b.Size=UDim2.new(0,88,1,0); b.BorderSizePixel=0
    b.Font=Enum.Font.GothamBold; b.TextSize=11; b.TextColor3=Color3.fromRGB(140,140,140)
    b.BackgroundColor3=Color3.fromRGB(35,35,45); b.Text=txt; b.Parent=tabRow
    Instance.new("UICorner",b).CornerRadius=UDim.new(0,6); return b
end
local hubTabBtn=mkTab("🌌  Hub"); hubTabBtn.TextColor3=Color3.fromRGB(255,255,255); hubTabBtn.BackgroundColor3=Color3.fromRGB(80,55,130)
local nukerTabBtn=mkTab("⚡  Nuker")
local settingsTabBtn=mkTab("⚙️  Settings")

local contentY=76

-- HUB PANEL
local hubPanel=Instance.new("Frame")
hubPanel.Size=UDim2.new(1,0,1,-contentY); hubPanel.Position=UDim2.new(0,0,0,contentY)
hubPanel.BackgroundTransparency=1; hubPanel.Parent=mainFrame

local dz=Color3.fromRGB(145,138,160)

local function mkHL(y,h,txt,col,align,bold)
    local l=Instance.new("TextLabel"); l.Size=UDim2.new(1,-pad*2,0,h); l.Position=UDim2.new(0,pad,0,y)
    l.BackgroundTransparency=1; l.Font=bold and Enum.Font.GothamBold or Enum.Font.Gotham
    l.TextSize=bold and 13 or 11; l.TextColor3=col; l.Text=txt
    l.TextXAlignment=align or Enum.TextXAlignment.Left; l.Parent=hubPanel; return l
end

local function mkHBtn(x,w,y,h)
    local b=Instance.new("TextButton"); b.Size=UDim2.new(0,w,0,h); b.Position=UDim2.new(0,x,0,y)
    b.BorderSizePixel=0; b.Font=Enum.Font.GothamBold; b.TextSize=10; b.TextColor3=Color3.fromRGB(255,255,255); b.Parent=hubPanel
    Instance.new("UICorner",b).CornerRadius=UDim.new(0,7); return b
end

-- Row 1: trainer toggles (BT / FS / PS) — radio style, one at a time
local btnW = math.floor((iw - 8) / 3)
local btBtn = mkHBtn(pad,          btnW, 6, 30)
local fsBtn = mkHBtn(pad+btnW+4,   btnW, 6, 30)
local psBtn = mkHBtn(pad+btnW*2+8, btnW, 6, 30)

-- Row 2: AR toggle + TP back
local arBtn=mkHBtn(pad, math.floor(iw/2)-2, 42, 26)
local tpBackBtn=mkHBtn(pad+math.floor(iw/2)+2, math.floor(iw/2)-2, 42, 26)
local aqBtn=mkHBtn(pad, iw, 74, 26)

local hubDiv=Instance.new("Frame"); hubDiv.Size=UDim2.new(1,-20,0,1); hubDiv.Position=UDim2.new(0,pad,0,107)
hubDiv.BackgroundColor3=Color3.fromRGB(55,45,75); hubDiv.BorderSizePixel=0; hubDiv.Parent=hubPanel

-- stat labels
local areaLbl  = mkHL(112,  18, "Trainer: off",       dz)
local modeLbl  = mkHL(130,  18, "Mode: ---",           dz)
local btLbl    = mkHL(148, 18, "BT: ...",             Color3.fromRGB(255,140,50))
local fsLbl    = mkHL(166, 18, "FS: ...",             Color3.fromRGB(100,180,255))
local psLbl    = mkHL(184, 18, "PS: ...",             Color3.fromRGB(200,100,255))
local hpLbl    = mkHL(202, 18, "HP: ...",             dz)
local nextLbl  = mkHL(220, 18, "Next zone: ---",      Color3.fromRGB(170,160,200))
local etaLbl   = mkHL(238, 18, "ETA: ---",            Color3.fromRGB(130,110,180))
local stLbl    = mkHL(256, 18, "Status: idle",        Color3.fromRGB(170,160,190))
local arLbl    = mkHL(274, 18, "AutoRespawn: on",     Color3.fromRGB(90,200,255))

local fusDivider=Instance.new("Frame"); fusDivider.Size=UDim2.new(1,-20,0,1); fusDivider.Position=UDim2.new(0,pad,0,298)
fusDivider.BackgroundColor3=Color3.fromRGB(80,50,120); fusDivider.BorderSizePixel=0; fusDivider.Parent=hubPanel

mkHL(304,14,"✨  FUSION TRACKER",Color3.fromRGB(200,160,255),nil,true)
local fusStatLbl=mkHL(322,18,"TP:  ---  [?]",  Color3.fromRGB(255,200,80))
local fusReqLbl =mkHL(340,18,"Next: ---",       Color3.fromRGB(200,170,255))
local fusPctLbl =mkHL(358,18,"Progress: ---",   Color3.fromRGB(100,220,100))
local fusRateLbl=mkHL(376,18,"Rate:  ---",       Color3.fromRGB(160,200,255))
local fusEtaLbl =mkHL(394,22,"ETA:   ---",       Color3.fromRGB(120,240,255),nil,true)
mkHL(422,14,"Antigravity 💜  |  BT:"..#btAreas.."  FS:"..#fsAreas.."  PS:"..#psAreas.." zones",Color3.fromRGB(70,60,100),Enum.TextXAlignment.Center)

-- TRAINER BUTTON LOGIC
local trainerBtns = {BT=btBtn, FS=fsBtn, PS=psBtn}
local trainerLabels = {BT="💪 BT", FS="👊 FS", PS="🔮 PS"}
local trainerColors = {
    BT = Color3.fromRGB(38,105,42),
    FS = Color3.fromRGB(30,90,160),
    PS = Color3.fromRGB(110,40,160),
}

local function refreshTrainerBtns()
    for key, btn in pairs(trainerBtns) do
        local on = (_G.ActiveTrainer == key)
        btn.Text = trainerLabels[key] .. ": " .. (on and "ON ✅" or "OFF ❌")
        TweenService:Create(btn,TweenInfo.new(0.15),{BackgroundColor3=on and trainerColors[key] or Color3.fromRGB(52,52,62)}):Play()
    end
end

local function setTrainer(key)
    if _G.ActiveTrainer == key then
        _G.ActiveTrainer = nil
    else
        _G.ActiveTrainer = key
    end
    refreshTrainerBtns()
    saveSettings()
end

btBtn.MouseButton1Click:Connect(function() setTrainer("BT") end)
fsBtn.MouseButton1Click:Connect(function() setTrainer("FS") end)
psBtn.MouseButton1Click:Connect(function() setTrainer("PS") end)

local function refreshARBtn()
    arBtn.Text="🔄 AR: "..(_G.AutoRespawnEnabled and "ON ✅" or "OFF ❌")
    arBtn.BackgroundColor3=_G.AutoRespawnEnabled and Color3.fromRGB(38,90,130) or Color3.fromRGB(52,52,62)
    arLbl.Text="AutoRespawn: "..(_G.AutoRespawnEnabled and "on" or "off")
    arLbl.TextColor3=_G.AutoRespawnEnabled and Color3.fromRGB(90,200,255) or Color3.fromRGB(150,150,150)
end
local function refreshTPBackBtn()
    tpBackBtn.Text="📍 TP Back: "..(_G.ARTeleportBack and "ON ✅" or "OFF ❌")
    tpBackBtn.BackgroundColor3=_G.ARTeleportBack and Color3.fromRGB(35,80,120) or Color3.fromRGB(45,45,55)
end

local function refreshAQBtn()
    aqBtn.Text="🎯 Auto Quest: "..(_G.AutoQuestEnabled and "ON ✅" or "OFF ❌")
    aqBtn.BackgroundColor3=_G.AutoQuestEnabled and Color3.fromRGB(30,120,80) or Color3.fromRGB(45,45,55)
end
refreshTrainerBtns(); refreshARBtn(); refreshTPBackBtn(); refreshAQBtn()
aqBtn.MouseButton1Click:Connect(function() _G.AutoQuestEnabled=not _G.AutoQuestEnabled refreshAQBtn() saveSettings() end)
arBtn.MouseButton1Click:Connect(function() _G.AutoRespawnEnabled=not _G.AutoRespawnEnabled refreshARBtn() saveSettings() end)
tpBackBtn.MouseButton1Click:Connect(function() _G.ARTeleportBack=not _G.ARTeleportBack refreshTPBackBtn() saveSettings() end)

-- NUKER PANEL
local nukerPanel=Instance.new("Frame")
nukerPanel.Size=UDim2.new(1,0,1,-contentY); nukerPanel.Position=UDim2.new(0,0,0,contentY)
nukerPanel.BackgroundTransparency=1; nukerPanel.Visible=false; nukerPanel.Parent=mainFrame

local function mkNL(y,h,txt,col,font,tsize,wrap)
    local l=Instance.new("TextLabel"); l.Size=UDim2.new(0,iw,0,h); l.Position=UDim2.new(0,pad,0,y)
    l.BackgroundTransparency=1; l.Font=font or Enum.Font.Gotham; l.TextSize=tsize or 12
    l.TextColor3=col or Color3.fromRGB(180,180,180); l.TextXAlignment=Enum.TextXAlignment.Left
    l.TextWrapped=wrap or false; l.Text=txt; l.Parent=nukerPanel; return l
end
local function mkNH(y,txt)
    local l=Instance.new("TextLabel"); l.Size=UDim2.new(0,iw,0,12); l.Position=UDim2.new(0,pad,0,y)
    l.BackgroundTransparency=1; l.Font=Enum.Font.GothamBold; l.TextSize=10
    l.TextColor3=Color3.fromRGB(100,100,100); l.TextXAlignment=Enum.TextXAlignment.Left; l.Text=txt; l.Parent=nukerPanel
end

local sphereLabel=mkNL(6,18,string.format("Sphere: %.1f  FS: %.2e",getSphereRadius(),LP:GetAttribute("FistStrength") or 0))
local priorityLabel=mkNL(26,14,"Targeting: all",Color3.fromRGB(255,200,60),Enum.Font.Code,10)
local statusLabel=mkNL(42,36,"Idle — press Start",Color3.fromRGB(150,150,150),Enum.Font.Gotham,12,true)
local mathLabel=mkNL(80,18,"Ray dist: --",Color3.fromRGB(100,200,100),Enum.Font.Code,11)
local errorLabel=mkNL(100,14,"",Color3.fromRGB(255,80,80),Enum.Font.Code,10)

mkNH(120,"TARGETS")
local toggleRow=Instance.new("Frame"); toggleRow.Size=UDim2.new(0,iw,0,28); toggleRow.Position=UDim2.new(0,pad,0,134)
toggleRow.BackgroundTransparency=1; toggleRow.Parent=nukerPanel
local tLayout=Instance.new("UIListLayout"); tLayout.FillDirection=Enum.FillDirection.Horizontal; tLayout.SortOrder=Enum.SortOrder.LayoutOrder; tLayout.Padding=UDim.new(0,4); tLayout.Parent=toggleRow

local function updateToggleColor(btn,name)
    local on=enabledTargets[name]
    TweenService:Create(btn,TweenInfo.new(0.15),{BackgroundColor3=on and Color3.fromRGB(40,160,80) or Color3.fromRGB(55,55,55)}):Play()
    btn.TextColor3=on and Color3.fromRGB(255,255,255) or Color3.fromRGB(110,110,110)
end
for i,name in ipairs({"Noob","Thug","Mafia","WereWolf","Robot","Sath","Phantom"}) do
    local tb=Instance.new("TextButton"); tb.Size=UDim2.new(0,42,1,0); tb.BackgroundColor3=Color3.fromRGB(55,55,55)
    tb.BorderSizePixel=0; tb.Font=Enum.Font.GothamBold; tb.TextSize=9; tb.Text=name; tb.LayoutOrder=i; tb.Parent=toggleRow
    Instance.new("UICorner",tb).CornerRadius=UDim.new(0,5); updateToggleColor(tb,name); toggleButtons[name]=tb
    tb.MouseButton1Click:Connect(function() enabledTargets[name]=not enabledTargets[name] updateToggleColor(tb,name) saveSettings() end)
end

mkNH(174,"MODE")
local modeRow=Instance.new("Frame"); modeRow.Size=UDim2.new(0,iw,0,28); modeRow.Position=UDim2.new(0,pad,0,188)
modeRow.BackgroundTransparency=1; modeRow.Parent=nukerPanel
local mLayout=Instance.new("UIListLayout"); mLayout.FillDirection=Enum.FillDirection.Horizontal; mLayout.SortOrder=Enum.SortOrder.LayoutOrder; mLayout.Padding=UDim.new(0,6); mLayout.Parent=modeRow
local tpBtn=Instance.new("TextButton"); tpBtn.Size=UDim2.new(0,140,1,0); tpBtn.BorderSizePixel=0; tpBtn.Font=Enum.Font.GothamBold; tpBtn.TextSize=11; tpBtn.Text="⚡ Teleport"; tpBtn.LayoutOrder=1; tpBtn.Parent=modeRow; Instance.new("UICorner",tpBtn).CornerRadius=UDim.new(0,5)
local fmBtn=Instance.new("TextButton"); fmBtn.Size=UDim2.new(0,140,1,0); fmBtn.BorderSizePixel=0; fmBtn.Font=Enum.Font.GothamBold; fmBtn.TextSize=11; fmBtn.Text="🚶 Free Move"; fmBtn.LayoutOrder=2; fmBtn.Parent=modeRow; Instance.new("UICorner",fmBtn).CornerRadius=UDim.new(0,5)
local function refreshModeButtons()
    TweenService:Create(tpBtn,TweenInfo.new(0.15),{BackgroundColor3=teleportMode and Color3.fromRGB(55,115,210) or Color3.fromRGB(55,55,55)}):Play(); tpBtn.TextColor3=teleportMode and Color3.fromRGB(255,255,255) or Color3.fromRGB(110,110,110)
    TweenService:Create(fmBtn,TweenInfo.new(0.15),{BackgroundColor3=not teleportMode and Color3.fromRGB(55,115,210) or Color3.fromRGB(55,55,55)}):Play(); fmBtn.TextColor3=not teleportMode and Color3.fromRGB(255,255,255) or Color3.fromRGB(110,110,110)
end
refreshModeButtons()
tpBtn.MouseButton1Click:Connect(function() teleportMode=true refreshModeButtons() saveSettings() end)
fmBtn.MouseButton1Click:Connect(function() teleportMode=false refreshModeButtons() saveSettings() end)

mkNH(228,"PRIORITY TARGET")
local prioBtn=Instance.new("TextButton"); prioBtn.Size=UDim2.new(0,iw,0,28); prioBtn.Position=UDim2.new(0,pad,0,242); prioBtn.BorderSizePixel=0; prioBtn.Font=Enum.Font.GothamBold; prioBtn.TextSize=11; prioBtn.Text="🟡  Priority ON"; prioBtn.TextColor3=Color3.fromRGB(255,255,255); prioBtn.BackgroundColor3=Color3.fromRGB(180,130,20); prioBtn.Parent=nukerPanel; Instance.new("UICorner",prioBtn).CornerRadius=UDim.new(0,5)
prioBtn.MouseButton1Click:Connect(function()
    priorityMode=not priorityMode
    TweenService:Create(prioBtn,TweenInfo.new(0.15),{BackgroundColor3=priorityMode and Color3.fromRGB(180,130,20) or Color3.fromRGB(55,55,55)}):Play()
    prioBtn.TextColor3=priorityMode and Color3.fromRGB(255,255,255) or Color3.fromRGB(110,110,110); prioBtn.Text=priorityMode and "🟡  Priority ON" or "⭕  Priority OFF"
    saveSettings()
end)

mkNH(282,"ANTI-IDLE")
local idleBtn=Instance.new("TextButton"); idleBtn.Size=UDim2.new(0,iw,0,28); idleBtn.Position=UDim2.new(0,pad,0,296); idleBtn.BorderSizePixel=0; idleBtn.Font=Enum.Font.GothamBold; idleBtn.TextSize=11; idleBtn.Text="🟢  Active"; idleBtn.TextColor3=Color3.fromRGB(255,255,255); idleBtn.BackgroundColor3=Color3.fromRGB(40,160,80); idleBtn.Parent=nukerPanel; Instance.new("UICorner",idleBtn).CornerRadius=UDim.new(0,5)
idleBtn.MouseButton1Click:Connect(function()
    antiIdle=not antiIdle
    TweenService:Create(idleBtn,TweenInfo.new(0.15),{BackgroundColor3=antiIdle and Color3.fromRGB(40,160,80) or Color3.fromRGB(55,55,55)}):Play()
    idleBtn.TextColor3=antiIdle and Color3.fromRGB(255,255,255) or Color3.fromRGB(110,110,110); idleBtn.Text=antiIdle and "🟢  Active" or "⭕  Off"
    saveSettings()
end)

mkNH(336,"AUTO-SKIP WEAK")
local skipBtn=Instance.new("TextButton"); skipBtn.Size=UDim2.new(0,iw,0,28); skipBtn.Position=UDim2.new(0,pad,0,350); skipBtn.BorderSizePixel=0; skipBtn.Font=Enum.Font.GothamBold; skipBtn.TextSize=11; skipBtn.Text="🟢  Active"; skipBtn.TextColor3=Color3.fromRGB(255,255,255); skipBtn.BackgroundColor3=Color3.fromRGB(40,160,80); skipBtn.Parent=nukerPanel; Instance.new("UICorner",skipBtn).CornerRadius=UDim.new(0,5)
skipBtn.MouseButton1Click:Connect(function()
    autoSkipWeak=not autoSkipWeak
    TweenService:Create(skipBtn,TweenInfo.new(0.15),{BackgroundColor3=autoSkipWeak and Color3.fromRGB(40,160,80) or Color3.fromRGB(55,55,55)}):Play()
    skipBtn.TextColor3=autoSkipWeak and Color3.fromRGB(255,255,255) or Color3.fromRGB(110,110,110); skipBtn.Text=autoSkipWeak and "🟢  Active" or "⭕  Off"
    saveSettings()
end)

local startBtn=Instance.new("TextButton"); startBtn.Size=UDim2.new(0,iw,0,34); startBtn.Position=UDim2.new(0,pad,0,392); startBtn.BackgroundColor3=Color3.fromRGB(40,180,80); startBtn.BorderSizePixel=0; startBtn.Font=Enum.Font.GothamBold; startBtn.TextSize=13; startBtn.TextColor3=Color3.fromRGB(255,255,255); startBtn.Text="▶  Start"; startBtn.Parent=nukerPanel; Instance.new("UICorner",startBtn).CornerRadius=UDim.new(0,6)

-- SETTINGS PANEL
local settingsPanel=Instance.new("Frame")
settingsPanel.Size=UDim2.new(1,0,1,-contentY); settingsPanel.Position=UDim2.new(0,0,0,contentY)
settingsPanel.BackgroundTransparency=1; settingsPanel.Visible=false; settingsPanel.Parent=mainFrame

local function mkSL(y,h,txt,col,bold)
    local l=Instance.new("TextLabel"); l.Size=UDim2.new(0,iw,0,h); l.Position=UDim2.new(0,pad,0,y)
    l.BackgroundTransparency=1; l.Font=bold and Enum.Font.GothamBold or Enum.Font.Gotham
    l.TextSize=bold and 13 or 11; l.TextColor3=col or Color3.fromRGB(180,180,180)
    l.TextXAlignment=Enum.TextXAlignment.Left; l.Text=txt; l.Parent=settingsPanel; return l
end
local function mkSBtn(y,h,txt,col)
    local b=Instance.new("TextButton"); b.Size=UDim2.new(0,iw,0,h); b.Position=UDim2.new(0,pad,0,y)
    b.BorderSizePixel=0; b.Font=Enum.Font.GothamBold; b.TextSize=11
    b.TextColor3=Color3.fromRGB(255,255,255); b.BackgroundColor3=col or Color3.fromRGB(55,55,55)
    b.Parent=settingsPanel; Instance.new("UICorner",b).CornerRadius=UDim.new(0,7); return b
end

local chars = "abcdefghijklmnopqrstuvwxyz0123456789"
local function randName(minL, maxL)
    local len = math.random(minL, maxL)
    local s = ""
    for i = 1, len do
        local idx = math.random(1, #chars)
        s = s .. chars:sub(idx, idx)
    end
    return s
end

local spoofEnabled = false
local fakeName = ""
local fakeSquad = ""
local spoofConn = nil
local plNameLabel = nil      -- cached CoreGui PlayerList label
local plNameConn  = nil      -- changed signal connection

local spoofHeader = mkSL(6, 16, "USERNAME SPOOFER", Color3.fromRGB(200,160,255), true)
local spoofStatusLbl = mkSL(26, 18, "Status: off", Color3.fromRGB(150,150,150))
local fakeNameLbl = mkSL(46, 18, "Fake name: ---", Color3.fromRGB(100,210,255))
local fakeSquadLbl = mkSL(64, 18, "Fake squad: ---", Color3.fromRGB(100,255,180))

local spoofToggle = mkSBtn(88, 30, "🔴  Spoofer OFF", Color3.fromRGB(55,55,55))
local rerollBtn = mkSBtn(124, 30, "🎲  Reroll Names", Color3.fromRGB(50,80,130))

-- cached label refs, resolved once when spoofer is enabled
local spoofRefs = nil

local function buildSpoofRefs()
    local pg = LP.PlayerGui
    local main = pg:FindFirstChild("MainGui")
    if not main then return nil end
    local menu = main:FindFirstChild("MenuFrame")
    if not menu then return nil end
    local info = menu:FindFirstChild("InfoFrame")
    local gf = menu:FindFirstChild("SquadFrame") and menu.SquadFrame:FindFirstChild("GangFrame")
    local refs = {}
    if info then
        refs.nameLabel  = info:FindFirstChild("NameLabel")
        refs.gangLabel  = info:FindFirstChild("GangLabel")
    end
    if gf then
        refs.gangName   = gf:FindFirstChild("GangName")
        refs.leaderLabel = gf:FindFirstChild("Leader")
        local nf        = gf:FindFirstChild("NoticeFrame")
        refs.notice1    = nf and nf:FindFirstChild("Notice")
        refs.notice2    = nf and nf:FindFirstChild("NoticeForMember")
        -- collect all member rows + their original names for revert
        refs.memberRows = {}
        local scroll = gf:FindFirstChild("MembersFrame") and gf.MembersFrame:FindFirstChild("Frame") and gf.MembersFrame.Frame:FindFirstChild("ScrollingFrame")
        if scroll then
            for _, row in ipairs(scroll:GetChildren()) do
                local mn = row:FindFirstChild("MemberName")
                if mn and mn.Text ~= "" then
                    table.insert(refs.memberRows, {label=mn, original=mn.Text, fake=randName(5,10)})
                end
            end
        end
        refs.leaderOriginal = refs.leaderLabel and refs.leaderLabel.Text or ""
    end
    -- overhead billboard
    local char = LP.Character
    local head = char and char:FindFirstChild("Head")
    local bb = head and head:FindFirstChild("OverheadBillboard")
    if bb then
        refs.overheadName = bb:FindFirstChild("NameLabel")
        local gangFr = bb:FindFirstChild("Gang_Frame")
        refs.overheadGang = gangFr and gangFr:FindFirstChild("Gang_Txt")
    end
    return refs
end

local function applySpoof(refs)
    if not refs then return end
    if refs.nameLabel    then refs.nameLabel.Text    = "Name : "       .. fakeName  end
    if refs.gangLabel    then refs.gangLabel.Text    = "Squad : "      .. fakeSquad end
    if refs.gangName     then refs.gangName.Text     = "Squad Name : " .. fakeSquad end
    if refs.leaderLabel  then refs.leaderLabel.Text  = "Leader : "     .. (refs.memberRows and refs.memberRows[1] and refs.memberRows[1].fake or fakeName) end
    if refs.notice1      then refs.notice1.Text      = "Welcome to "   .. fakeSquad .. "!" end
    if refs.notice2      then refs.notice2.Text      = "Welcome to "   .. fakeSquad .. "!" end
    if refs.memberRows   then for _, row in ipairs(refs.memberRows) do row.label.Text = row.fake end end
    if refs.overheadName then refs.overheadName.Text = fakeName end
    if refs.overheadGang then refs.overheadGang.Text = "[Member] " .. fakeSquad end
end

local function revertSpoof(refs)
    if not refs then return end
    if refs.nameLabel    then refs.nameLabel.Text    = "Name : " .. LP.Name end
    if refs.gangLabel    then refs.gangLabel.Text    = "Squad : ApexKnight" end
    if refs.gangName     then refs.gangName.Text     = "Squad Name : ApexKnight" end
    if refs.leaderLabel  then refs.leaderLabel.Text  = refs.leaderOriginal or "" end
    if refs.notice1      then refs.notice1.Text      = "Welcome to ApexKnight!" end
    if refs.notice2      then refs.notice2.Text      = "Welcome to ApexKnight!" end
    if refs.memberRows   then for _, row in ipairs(refs.memberRows) do row.label.Text = row.original end end
    if refs.overheadName then refs.overheadName.Text = LP.Name end
    if refs.overheadGang then refs.overheadGang.Text = "[Member] ApexKnight" end
    -- revert CoreGui playerlist label
    if plNameLabel and plNameLabel.Parent then plNameLabel.Text = LP.DisplayName end
    if plNameConn then plNameConn:Disconnect(); plNameConn = nil end
    plNameLabel = nil
end
local function refreshSpoofUI()
    if spoofEnabled then
        spoofToggle.Text = "🟢  Spoofer ON"
        TweenService:Create(spoofToggle,TweenInfo.new(0.15),{BackgroundColor3=Color3.fromRGB(40,160,80)}):Play()
        spoofStatusLbl.Text = "Status: active"
        spoofStatusLbl.TextColor3 = Color3.fromRGB(90,210,90)
    else
        spoofToggle.Text = "🔴  Spoofer OFF"
        TweenService:Create(spoofToggle,TweenInfo.new(0.15),{BackgroundColor3=Color3.fromRGB(55,55,55)}):Play()
        spoofStatusLbl.Text = "Status: off"
        spoofStatusLbl.TextColor3 = Color3.fromRGB(150,150,150)
    end
    fakeNameLbl.Text = "Fake name: " .. (spoofEnabled and fakeName or "---")
    fakeSquadLbl.Text = "Fake squad: " .. (spoofEnabled and fakeSquad or "---")
end

spoofToggle.MouseButton1Click:Connect(function()
    spoofEnabled = not spoofEnabled
    if spoofEnabled then
        fakeName = randName(5, 10)
        fakeSquad = randName(5, 10)
        spoofRefs = buildSpoofRefs()
        applySpoof(spoofRefs)
        -- find and hook CoreGui playerlist label (display name, event-driven only)
        local pl = game:GetService("CoreGui"):FindFirstChild("PlayerList")
        if pl then
            for _, v in ipairs(pl:GetDescendants()) do
                if v:IsA("TextLabel") and v.Name == "PlayerName" and v.Text == LP.DisplayName then
                    plNameLabel = v
                    v.Text = fakeName
                    if plNameConn then plNameConn:Disconnect() end
                    plNameConn = v:GetPropertyChangedSignal("Text"):Connect(function()
                        if spoofEnabled and v.Text ~= fakeName then v.Text = fakeName end
                    end)
                    break
                end
            end
        end
        if spoofConn then spoofConn:Disconnect() end
        spoofConn = game:GetService("RunService").Heartbeat:Connect(function()
            applySpoof(spoofRefs)
        end)
    else
        if spoofConn then spoofConn:Disconnect(); spoofConn = nil end
        revertSpoof(spoofRefs)
        spoofRefs = nil
    end
    refreshSpoofUI()
end)

rerollBtn.MouseButton1Click:Connect(function()
    if not spoofEnabled then return end
    fakeName = randName(5, 10)
    fakeSquad = randName(5, 10)
    applySpoof(spoofRefs)
    refreshSpoofUI()
end)

refreshSpoofUI()

-- TAB SWITCHING
local function switchTab(tab)
    hubPanel.Visible=(tab=="hub"); nukerPanel.Visible=(tab=="nuker"); settingsPanel.Visible=(tab=="settings")
    local tabs = {hub=hubTabBtn, nuker=nukerTabBtn, settings=settingsTabBtn}
    for k,b in pairs(tabs) do
        local on=(k==tab)
        TweenService:Create(b,TweenInfo.new(0.15),{BackgroundColor3=on and Color3.fromRGB(80,55,130) or Color3.fromRGB(35,35,45)}):Play()
        b.TextColor3=on and Color3.fromRGB(255,255,255) or Color3.fromRGB(140,140,140)
    end
end
hubTabBtn.MouseButton1Click:Connect(function() switchTab("hub") end)
nukerTabBtn.MouseButton1Click:Connect(function() switchTab("nuker") end)
settingsTabBtn.MouseButton1Click:Connect(function() switchTab("settings") end)
switchTab("hub")

-- DRAG
local dragging,dragStart,startPos
titleBar.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then dragging=true;dragStart=i.Position;startPos=mainFrame.Position end end)
titleBar.InputChanged:Connect(function(i) if dragging and i.UserInputType==Enum.UserInputType.MouseMovement then local d=i.Position-dragStart; mainFrame.Position=UDim2.new(startPos.X.Scale,startPos.X.Offset+d.X,startPos.Y.Scale,startPos.Y.Offset+d.Y) end end)
titleBar.InputEnded:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then dragging=false end end)

-- NUKER LOOP
startBtn.MouseButton1Click:Connect(function()
    nukerRunning=not nukerRunning
    if nukerRunning then
        startBtn.Text="■  Stop"; TweenService:Create(startBtn,TweenInfo.new(0.2),{BackgroundColor3=Color3.fromRGB(200,50,50)}):Play()
        statusLabel.Text="🔍 Searching..."; statusLabel.TextColor3=Color3.fromRGB(255,200,50)
        task.spawn(function()
            while nukerRunning and hubAlive do
                if not character or not hrp or not hrp.Parent then statusLabel.Text="⏳ Waiting for character..."; task.wait(1); continue end
                local alive=getAlive()
                if #alive==0 then statusLabel.Text="Waiting for spawns..."; statusLabel.TextColor3=Color3.fromRGB(150,150,150); mathLabel.Text="Ray dist: --"; priorityLabel.Text="Targeting: none"; task.wait(0.5); continue end
                local currentType=alive[1].name
                priorityLabel.Text=string.format("Targeting: %s (%.0e tk)",currentType,tokenValues[currentType] or 0)
                local radius=getSphereRadius(); sphereLabel.Text=string.format("Sphere: %.1f  FS: %.2e",radius,LP:GetAttribute("FistStrength") or 0)
                local ok,_=pcall(findBestLine,alive,radius); if not ok then task.wait(0.5); continue end
                local origin,dir,maxDist,centroid,hits=findBestLine(alive,radius); if not origin then task.wait(0.5); continue end
                errorLabel.Text=""
                statusLabel.Text=string.format("🔥 Hitting %d / %d",hits,#alive); statusLabel.TextColor3=Color3.fromRGB(255,120,50)
                mathLabel.Text=string.format("Max dev: %.2f / %.1f  %s",maxDist,radius,hits==#alive and "✅" or "⚠️"); mathLabel.TextColor3=hits==#alive and Color3.fromRGB(100,220,100) or Color3.fromRGB(255,160,50)
                if teleportMode then hrp.CFrame=CFrame.new(origin,origin+dir); task.wait(0.05) end
                pcall(function() UseSkill:FireServer("EnergySphere",centroid+dir*behindDist) end)
                task.wait(burstSpeed)
            end
            statusLabel.Text="Idle — press Start"; statusLabel.TextColor3=Color3.fromRGB(150,150,150); mathLabel.Text="Ray dist: --"; errorLabel.Text=""; priorityLabel.Text="Targeting: all"
        end)
    else
        startBtn.Text="▶  Start"; TweenService:Create(startBtn,TweenInfo.new(0.2),{BackgroundColor3=Color3.fromRGB(40,180,80)}):Play()
    end
end)

-- HUB LOOP
task.spawn(function()
    local activeArea   = nil
    local activeKey    = nil
    local btSamples={};local fsSamples={};local psSamples={}

    local function recordStat(tbl,val)
        local now=tick(); table.insert(tbl,{t=now,v=val})
        while tbl[1] and (now-tbl[1].t)>30 do table.remove(tbl,1) end
    end
    local function getRate(tbl)
        if #tbl<2 then return 0 end
        local dt=tbl[#tbl].t-tbl[1].t; if dt<1 then return 0 end
        return math.max(0,(tbl[#tbl].v-tbl[1].v)/dt)
    end

    local lastFusionPrint=0

    while true do
        task.wait(0.8)
        if not hubAlive or not mainFrame.Parent then break end

        local bt  = tonumber(LP:GetAttribute("BodyToughness"))  or 0
        local fs  = tonumber(LP:GetAttribute("FistStrength"))   or 0
        local ps  = tonumber(LP:GetAttribute("PsychicPower"))   or 0
        local btM = LP:GetAttribute("BodyToughnessMultiplier")  or 1
        local fsM = LP:GetAttribute("FistStrengthMultiplier")   or 1
        local psM = LP:GetAttribute("PsychicPowerMultiplier")   or 1

        recordStat(btSamples,bt); recordStat(fsSamples,fs); recordStat(psSamples,ps)
        local btRate=getRate(btSamples); local fsRate=getRate(fsSamples); local psRate=getRate(psSamples)

        btLbl.Text=string.format("BT: %s  (x%s  +%s/s)", fmtNum(bt), fmtNum(btM), fmtNum(btRate))
        fsLbl.Text=string.format("FS: %s  (x%s  +%s/s)", fmtNum(fs), fmtNum(fsM), fmtNum(fsRate))
        psLbl.Text=string.format("PS: %s  (x%s  +%s/s)", fmtNum(ps), fmtNum(psM), fmtNum(psRate))

        -- fusion tracker
        local tp=tonumber(LP:GetAttribute("TotalPower")) or 0
        local fusionName=tostring(LP:GetAttribute("FusionName") or "?")
        local nextTier=getNextFusionTier(); recordFusion(tp); local fusRate2=getFusionRate()
        if nextTier then
            local req=nextTier.req; local remaining=math.max(0,req-tp)
            local pct=math.min(100,(tp/req)*100); local etaSecs=fusRate2>0 and (remaining/fusRate2) or math.huge
            fusStatLbl.Text=string.format("TP:  %s  [%s]",fmtNum(tp),fusionName)
            fusReqLbl.Text=string.format("Next: %s  (%s req)",nextTier.name,fmtNum(req))
            fusPctLbl.Text=string.format("Progress: %.4f%%",pct)
            fusRateLbl.Text=string.format("Rate:  +%s/s",fmtNum(fusRate2))
            if fusRate2>0 then
                fusEtaLbl.Text="ETA:   "..fmtETALong(etaSecs); fusEtaLbl.TextColor3=Color3.fromRGB(120,240,255)
                local now=tick(); if now-lastFusionPrint>=60 then lastFusionPrint=now warn(string.format("[Fusion] TP=%.3e  %s→%s  ETA=%s",tp,fusionName,nextTier.name,fmtETALong(etaSecs))) end
            else fusEtaLbl.Text="ETA:   warming up..."; fusEtaLbl.TextColor3=Color3.fromRGB(150,150,150) end
        else
            fusStatLbl.Text=string.format("TP:  %s  [%s]",fmtNum(tp),fusionName); fusReqLbl.Text="ALL MAXED 🏆"; fusPctLbl.Text="Progress: 100%"
            fusRateLbl.Text=string.format("Rate:  +%s/s",fmtNum(fusRate2)); fusEtaLbl.Text="Maxed! ✨"; fusEtaLbl.TextColor3=Color3.fromRGB(255,215,0)
        end

        local char=LP.Character; local hum=char and char:FindFirstChild("Humanoid"); local crp=char and char:FindFirstChild("HumanoidRootPart")
        if hum and hum.MaxHealth>0 then
            local pct=hum.Health/hum.MaxHealth
            hpLbl.Text=string.format("HP: %d%% (%d/%d)",math.floor(pct*100),math.floor(hum.Health),math.floor(hum.MaxHealth))
            hpLbl.TextColor3=pct>0.6 and Color3.fromRGB(90,210,90) or pct>0.25 and Color3.fromRGB(255,185,50) or Color3.fromRGB(255,60,60)
        else hpLbl.Text="HP: dead"; hpLbl.TextColor3=Color3.fromRGB(200,60,60) end

        -- trainer logic
        local key=_G.ActiveTrainer
        if not key then
            if activeArea then activeArea=nil; activeKey=nil end
            areaLbl.Text="Trainer: off"; areaLbl.TextColor3=dz
            modeLbl.Text="Mode: ---"; modeLbl.TextColor3=dz
            stLbl.Text="Status: idle"; stLbl.TextColor3=dz
            nextLbl.Text="Next zone: ---"; nextLbl.TextColor3=dz; etaLbl.Text=""
            continue
        end

        if not crp or not hum or hum.Health<=0 then
            areaLbl.Text="Trainer: dead, waiting..."; areaLbl.TextColor3=Color3.fromRGB(180,180,180)
            stLbl.Text="Status: respawning"; stLbl.TextColor3=Color3.fromRGB(180,180,180); continue
        end

        local cfg=trainerConfig[key]
        local statVal=tonumber(LP:GetAttribute(cfg.stat)) or 0
        local statRate=key=="BT" and btRate or key=="FS" and fsRate or psRate

        local bestArea
        if key == "BT" then
            bestArea = getBestArea(cfg.areas, statVal)
        else
            bestArea = nil
            for _, a in ipairs(cfg.areas) do
                if statVal >= a.req then bestArea = a end
            end
        end
        local nextZone=getNextAreaFrom(cfg.areas, bestArea)

        -- update next zone label
        if nextZone then
            local needed=(key == "BT" and nextZone.req/dtDivisor or nextZone.req) - statVal
            if needed<=0 then
                nextLbl.Text="Next: "..nextZone.name.." ✅ UNLOCKED"; nextLbl.TextColor3=Color3.fromRGB(90,210,90); etaLbl.Text=""
            else
                local eta=statRate>0 and (needed/statRate) or math.huge
                nextLbl.Text=string.format("Next: %s (need %s)",nextZone.name,fmtNum(key == "BT" and nextZone.req/dtDivisor or nextZone.req)); nextLbl.TextColor3=Color3.fromRGB(170,160,200)
                etaLbl.Text=string.format("ETA: %s  (+%s)",fmtTime(eta),fmtNum(needed)); etaLbl.TextColor3=Color3.fromRGB(130,110,180)
            end
        else nextLbl.Text="Next: ALL MAXED 🏆"; nextLbl.TextColor3=Color3.fromRGB(255,215,0); etaLbl.Text="" end

        -- switch area if trainer changed or better area available
        if bestArea and (activeArea~=bestArea or activeKey~=key) then
            activeArea=bestArea; activeKey=key; _G.activeTrainArea=activeArea
            -- Only teleport if not already inside the new area
            if not isInsideArea(crp.Position, activeArea) then
                stLbl.Text="Status: teleporting to "..activeArea.name; stLbl.TextColor3=Color3.fromRGB(255,200,50)
                crp.CFrame = getAreaLandCFrame(activeArea)
            end
        end

        if not activeArea then
            areaLbl.Text="Trainer: no zone yet"; areaLbl.TextColor3=dz
            stLbl.Text="Status: stat too low for any zone"; stLbl.TextColor3=dz; continue
        end

        -- Only teleport back if we are genuinely outside the hitbox
        if not isInsideArea(crp.Position, activeArea) then
            crp.CFrame = getAreaLandCFrame(activeArea)
        end

        areaLbl.Text=string.format("Trainer: %s → %s",key,activeArea.name); areaLbl.TextColor3=cfg.color
        if key ~= "BT" then
            modeLbl.Text="Mode: Grinding 💪"; modeLbl.TextColor3=cfg.color
            stLbl.Text="Status: grinding "..key.."..."; stLbl.TextColor3=cfg.color
        elseif statVal>=(activeArea.req*4) then
            modeLbl.Text="Mode: AFK 😴 (no damage)"; modeLbl.TextColor3=Color3.fromRGB(90,200,255)
            stLbl.Text="Status: AFK grinding BT..."; stLbl.TextColor3=Color3.fromRGB(90,200,255)
        else
            local pct=math.floor((statVal/(activeArea.req*4))*100)
            modeLbl.Text=string.format("Mode: Death Train 💀 (%d%% to AFK)",pct); modeLbl.TextColor3=cfg.color
            stLbl.Text="Status: dying for BT..."; stLbl.TextColor3=cfg.color
        end
    end
end)

-- AUTO QUEST LOOP
task.spawn(function()
    local rs = game:GetService("ReplicatedStorage")
    local timerQuestClaim = rs.RemoteEvents.TimerQuestClaim
    local dailyMod  = require(rs.Modules.Quests.TimedQuests.DailyQuests)
    local weeklyMod = require(rs.Modules.Quests.TimedQuests.WeeklyQuests)
    local questTypes = {
        {mod=dailyMod,  label="Daily"},
        {mod=weeklyMod, label="Weekly"},
    }
    local prefixes = {Daily="DQ", Weekly="WQ"}
    while hubAlive do
        task.wait(3)
        if not _G.AutoQuestEnabled then continue end
        for _, qt in ipairs(questTypes) do
            local prefix = prefixes[qt.label]
            for k, v in pairs(qt.mod:GetAllQuests()) do
                if not qt.mod:IsQuestUnlocked(LP, v) then continue end
                for k2, v3 in pairs(v.Tasks) do
                    local claimedKey = prefix .. k .. k2
                    if LP:GetAttribute(claimedKey) then continue end
                    local startVal = LP:GetAttribute(prefix .. k2 .. "Start") or 0
                    if startVal >= v3 then
                        timerQuestClaim:FireServer(k, k2, qt.label)
                        task.wait(0.3)
                    end
                end
            end
        end
    end
end)

warn("[AG] Ready — BT:"..#btAreas.." FS:"..#fsAreas.." PS:"..#psAreas.." zones")
warn("[AutoRespawn] Active")
warn("[LineShotNuker] Ready")
warn("[FusionTracker] Active")



