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
local VirtualUser      = game:GetService("VirtualUser")
local VIM              = game:GetService("VirtualInputManager")
local LP           = Players.LocalPlayer
local PG           = LP:WaitForChild("PlayerGui")
local Camera       = workspace.CurrentCamera

local RemoteEvents     = game.ReplicatedStorage.RemoteEvents
local RefreshCharacter = RemoteEvents.RefreshCharacter
local Loaded           = RemoteEvents.Loaded
local UseSkill         = RemoteEvents.UseSkill
local JF_Train         = RemoteEvents.JF_Train
local FS_Train         = RemoteEvents.FS_Train
local SetWeight        = RemoteEvents.SetWeight

_G.ActiveTrainer      = nil
_G.AutoEquipEnabled   = true
_G.AutoBoxEnabled     = false
_G.AutoRespawnEnabled = true
_G.ARTeleportBack     = true
_G.AutoQuestEnabled   = true
_G.JFEnabled          = false
_G.isCapturingFort    = false
local fsAutoClick     = false
local fsClickInterval = 0.1
if _G.hubKillFlag then _G.hubKillFlag() end
local hubAlive = true
_G.nukerRunning = false
_G.hubConnections = {}
local function track(conn) table.insert(_G.hubConnections, conn); return conn end
_G.hubKillFlag = function()
    hubAlive = false
    _G.nukerRunning = false
    _G.isCapturingFort = false
    if _G.hubConnections then
        for _, c in ipairs(_G.hubConnections) do pcall(function() c:Disconnect() end) end
        _G.hubConnections = {}
    end
end

local lastDeathCFrame = nil
local dtDivisor       = 20

local suffixes = {
    {"Qid",1e48},{"Qad",1e45},
    {"Td", 1e42},{"DD", 1e39},{"Ud", 1e36},
    {"Dc", 1e33},{"No", 1e30},{"Oc", 1e27},{"Sp", 1e24},
    {"Sx", 1e21},{"Qi", 1e18},{"Qa", 1e15},
    {"T",  1e12},{"B",  1e9}, {"M",  1e6}, {"K",  1e3},
}

function parseName(name)
    for _, pair in ipairs(suffixes) do
        local n = name:match("^(%d+%.?%d*)" .. pair[1] .. "$")
        if n then return tonumber(n) * pair[2] end
    end
    return tonumber(name)
end

function fmtNum(n)
    if not n or n <= 0 then return "0" end
    for i = 1, #suffixes do
        if n >= suffixes[i][2] then
            return string.format("%.3g%s", n / suffixes[i][2], suffixes[i][1])
        end
    end
    return tostring(math.floor(n))
end

function fmtTime(secs)
    if secs <= 0 or secs ~= secs then return "now" end
    if secs > 86400*30 then return ">30d" end
    if secs > 86400 then return string.format("%.1fd", secs/86400) end
    if secs > 3600  then return string.format("%.1fh", secs/3600) end
    if secs > 60    then return string.format("%.1fm", secs/60) end
    return string.format("%.0fs", secs)
end

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
    if secs <= 0 or secs ~= secs then return "Ready!" end
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

local trainerConfig = {
    BT = {areas=btAreas, stat="BodyToughness",   multiStat="BodyToughnessMultiplier",   color=Color3.fromRGB(255,140,50)},
    FS = {areas=fsAreas, stat="FistStrength",     multiStat="FistStrengthMultiplier",    color=Color3.fromRGB(100,180,255)},
    PS = {areas=psAreas, stat="PsychicPower",     multiStat="PsychicPowerMultiplier",    color=Color3.fromRGB(200,100,255)},
    JF = {areas=nil,          stat="JumpForce",         multiStat="JumpForceMultiplier",       color=Color3.fromRGB(80,220,120)},
}

local function getAreaLandCFrame(a)
    return a.part.CFrame * CFrame.new(0, a.halfY - 1, 0)
end

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
local manualTargets = {Noob=true,Thug=true,Mafia=true,WereWolf=true,Robot=false,Sath=true,Phantom=true}

local SETTINGS_FILE = "ag_hub_settings.json"
function lB(s, key, def)
    local v = s:match('"' .. key .. '":(%a+)')
    if v == "true" then return true elseif v == "false" then return false end
    return def
end
function lS(s, key)
    return s:match('"' .. key .. '":"([^"]+)"')
end
function lN(s, key, def)
    local v = s:match('"' .. key .. '":([%d%.eE%+%-]+)')
    if v then return tonumber(v) end
    return def
end
local _sv = nil
local _svOk, _svErr = pcall(function() if readfile then local r = readfile(SETTINGS_FILE) if r and #r > 2 then _sv = r end end end)
if not _svOk then warn('[Settings] Load error: ' .. tostring(_svErr)) end
if _sv then warn('[Settings] Loaded from disk OK') else warn('[Settings] No save file, using defaults') end
if _sv then
    _G.ActiveTrainer      = lS(_sv, "activeTrainer")
    if _G.ActiveTrainer == "JF" then _G.ActiveTrainer = nil end
    _G.AutoRespawnEnabled = lB(_sv, "autoRespawn",    true)
    _G.ARTeleportBack     = lB(_sv, "arTeleportBack", true)
    _G.AutoQuestEnabled   = lB(_sv, "autoQuest",      true)
    _G.AutoEquipEnabled   = lB(_sv, "autoEquip",      true)
    _G.AutoBoxEnabled     = lB(_sv, "autoBox",        false)
    manualTargets.Noob     = lB(_sv, "Noob",     true)
    manualTargets.Thug     = lB(_sv, "Thug",     true)
    manualTargets.Mafia    = lB(_sv, "Mafia",    true)
    manualTargets.WereWolf = lB(_sv, "WereWolf", true)
    manualTargets.Robot    = lB(_sv, "Robot",    false)
    manualTargets.Sath     = lB(_sv, "Sath",     true)
    manualTargets.Phantom  = lB(_sv, "Phantom",  true)
    for k,v in pairs(manualTargets) do enabledTargets[k]=v end
end
if _sv then
    nukerRunning = lB(_sv, "nukerRunning", false)
    teleportMode = lB(_sv, "teleportMode", true)
    antiIdle     = lB(_sv, "antiIdle",     true)
    autoSkipWeak = lB(_sv, "autoSkipWeak", true)
    priorityMode = lB(_sv, "priorityMode", true)
    _G.JFEnabled  = lB(_sv, "jfEnabled",     false)
    fsAutoClick   = lB(_sv, "fsAutoClick",   false)
end
local _svStr = _sv or ""
_G.AutoBoxInterval = lN(_svStr, "autoBoxInterval", 0.05)
_G.AutoRollEnabled = lB(_svStr, "autoRoll", false)
_G.AutoBoxTiers = {
    Tier1 = lB(_svStr, "boxTier1", true),
    Tier2 = lB(_svStr, "boxTier2", true),
    Tier3 = lB(_svStr, "boxTier3", true),
    Tier4 = lB(_svStr, "boxTier4", true),
}
local function saveSettings()
    local at = _G.ActiveTrainer and ('"' .. _G.ActiveTrainer .. '"') or "null"
    local et = enabledTargets
    local json = string.format(
        '{"activeTrainer":%s,"autoRespawn":%s,"arTeleportBack":%s,"autoQuest":%s,"autoEquip":%s,"autoBox":%s,"teleportMode":%s,"antiIdle":%s,"nukerRunning":%s,"autoSkipWeak":%s,"priorityMode":%s,"jfEnabled":%s,"fsAutoClick":%s,"Noob":%s,"Thug":%s,"Mafia":%s,"WereWolf":%s,"Robot":%s,"Sath":%s,"Phantom":%s,"autoBoxInterval":%s,"autoRoll":%s,"boxTier1":%s,"boxTier2":%s,"boxTier3":%s,"boxTier4":%s}',
        at,
        tostring(_G.AutoRespawnEnabled),
        tostring(_G.ARTeleportBack),
        tostring(_G.AutoQuestEnabled),
        tostring(_G.AutoEquipEnabled),
        tostring(_G.AutoBoxEnabled),
        tostring(teleportMode),
        tostring(antiIdle),
        tostring(nukerRunning),
        tostring(autoSkipWeak),
        tostring(priorityMode),
        tostring(_G.JFEnabled == true),
        tostring(fsAutoClick),
        tostring(manualTargets.Noob),
        tostring(manualTargets.Thug),
        tostring(manualTargets.Mafia),
        tostring(manualTargets.WereWolf),
        tostring(manualTargets.Robot),
        tostring(manualTargets.Sath),
        tostring(manualTargets.Phantom),
        tostring(_G.AutoBoxInterval or 0.05),
        tostring(_G.AutoRollEnabled == true),
        tostring(_G.AutoBoxTiers and _G.AutoBoxTiers.Tier1 == true),
        tostring(_G.AutoBoxTiers and _G.AutoBoxTiers.Tier2 == true),
        tostring(_G.AutoBoxTiers and _G.AutoBoxTiers.Tier3 == true),
        tostring(_G.AutoBoxTiers and _G.AutoBoxTiers.Tier4 == true)
    )
    local ok, err = pcall(function() if writefile then writefile(SETTINGS_FILE, json) end end)
    if not ok then warn("[Settings] Save failed: " .. tostring(err)) end
end

local character = LP.Character or LP.CharacterAdded:Wait()
local hrp       = character:WaitForChild("HumanoidRootPart", 5)
track(LP.CharacterAdded:Connect(function(c) character=c; hrp=c:WaitForChild("HumanoidRootPart") end))

track(LP.Idled:Connect(function() if not antiIdle then return end VirtualUser:CaptureController() VirtualUser:ClickButton2(Vector2.new()) end))
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
    track(hum.HealthChanged:Connect(function(newHealth)
        if newHealth<lastHealth then entry.hitCount+=1 end
        lastHealth=newHealth
        if newHealth<=0 and autoSkipWeak and entry.hitCount<=3 then enabledTargets[model.Name]=false refreshToggleColor(model.Name) end
    end))
end

local function buildCache() pruneCache(); for _,obj in ipairs(workspace:GetDescendants()) do tryRegisterModel(obj) end end

track(workspace.DescendantAdded:Connect(function(child)
    if not (child:IsA("Model") and trackable[child.Name]) then return end
    if registeredModels[child] then return end
    task.spawn(function()
        for _=1,5 do task.wait(0.25) if not child.Parent then return end if getRootPart(child) and child:FindFirstChildOfClass("Humanoid") then tryRegisterModel(child) return end end
        local rp=child:FindFirstChild("HumanoidRootPart") or child:FindFirstChild("Torso")
        local hum=child:FindFirstChildOfClass("Humanoid") or child:WaitForChild("Humanoid",3)
        if rp and hum then tryRegisterModel(child) end
    end)
end))

task.spawn(buildCache)

local function restoreUI()
    local pg=LP.PlayerGui
    for _,name in ipairs({"MainGui","QuestsGui","SkillCooldowns"}) do local gui=pg:FindFirstChild(name) if gui then gui.Enabled=true end end
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
    track(hum.Died:Connect(function()
        if not _G.AutoRespawnEnabled then return end
        pcall(function()
            local diedScript = char:FindFirstChild("Died")
            if diedScript then diedScript.Enabled = false end
        end)
        local crp=char:FindFirstChild("HumanoidRootPart"); if crp then lastDeathCFrame=crp.CFrame end
        task.spawn(function()
            for i=1,20 do
                pcall(function()
                    Camera.CameraType = Enum.CameraType.Custom
                    TweenService:Create(Camera, TweenInfo.new(0), {CFrame=Camera.CFrame}):Play()
                    LP.PlayerGui.IntroGui.Enabled = false
                    Lighting.Blur.Size = 0
                end)
                task.wait(0.05)
            end
        end)
        RefreshCharacter:FireServer()
        local newChar=LP.CharacterAdded:Wait()
        local newHum=newChar:WaitForChild("Humanoid",5)
        local newCRP=newChar:WaitForChild("HumanoidRootPart",5)
        if newHum then Camera.CameraType=Enum.CameraType.Custom; Camera.CameraSubject=newHum end
        task.wait(0.025)
        Loaded:FireServer()
        restoreUI()
        if _G.ARTeleportBack and newCRP and not _G.dtModeActive then
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
    end))
end

if LP.Character then
    hookCharacter(LP.Character)
    fixCamera(LP.Character)
    task.spawn(function()
        task.wait(0.3)
        pcall(function() Loaded:FireServer() end)
        task.wait(0.05)
        restoreUI()
        warn("[AutoRespawn] Join-time load fired")
    end)
end
track(LP.CharacterAdded:Connect(function(char) hookCharacter(char) fixCamera(char) end))

-- GUI
local sg=Instance.new("ScreenGui"); sg.Name="CombinedHubGui"; sg.ResetOnSpawn=false
pcall(function() sg.Parent=CG end); if not sg.Parent then sg.Parent=PG end

local frameW=340; local pad=10; local iw=frameW-pad*2

local mainFrame=Instance.new("Frame")
mainFrame.Size=UDim2.new(0,frameW,0,618)
mainFrame.AnchorPoint=Vector2.new(0.5,0.5)
mainFrame.Position=UDim2.new(0.5,0,0.5,0)
mainFrame.BackgroundColor3=Color3.fromRGB(12,12,18); mainFrame.BorderSizePixel=0
mainFrame.Active=true; mainFrame.Draggable=false; mainFrame.Parent=sg
Instance.new("UICorner",mainFrame).CornerRadius=UDim.new(0,12)

local hubUIScale=Instance.new("UIScale")
hubUIScale.Parent=mainFrame
local function refreshHubScale()
    local vp=workspace.CurrentCamera.ViewportSize
    local scaleX=vp.X/1280
    local scaleY=vp.Y/720
    local s=math.min(scaleX,scaleY)
    s=math.clamp(s,0.55,1)
    hubUIScale.Scale=s
end
refreshHubScale()
workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(refreshHubScale)
local mainStroke=Instance.new("UIStroke",mainFrame); mainStroke.Color=Color3.fromRGB(100,75,150); mainStroke.Thickness=1.5

local titleBar=Instance.new("Frame")
titleBar.Size=UDim2.new(1,0,0,36); titleBar.BackgroundColor3=Color3.fromRGB(20,16,30)
titleBar.BorderSizePixel=0; titleBar.Parent=mainFrame
Instance.new("UICorner",titleBar).CornerRadius=UDim.new(0,12)
local titleLbl=Instance.new("TextLabel")
titleLbl.Size=UDim2.new(1,-12,1,0); titleLbl.Position=UDim2.new(0,12,0,0); titleLbl.BackgroundTransparency=1
titleLbl.Font=Enum.Font.GothamBold; titleLbl.TextSize=13; titleLbl.TextColor3=Color3.fromRGB(220,210,255)
titleLbl.Text="🪐 Antigravity Hub | Line Shot 💥"; titleLbl.TextXAlignment=Enum.TextXAlignment.Left; titleLbl.Parent=titleBar

local tabRow=Instance.new("Frame")
tabRow.Size=UDim2.new(1,-16,0,28); tabRow.Position=UDim2.new(0,8,0,40)
tabRow.BackgroundTransparency=1; tabRow.Parent=mainFrame
local tabLayout=Instance.new("UIListLayout"); tabLayout.FillDirection=Enum.FillDirection.Horizontal; tabLayout.Padding=UDim.new(0,6); tabLayout.Parent=tabRow

local function mkTab(txt)
    local b=Instance.new("TextButton"); b.Size=UDim2.new(0.2,-5,1,0); b.BorderSizePixel=0
    b.Font=Enum.Font.GothamBold; b.TextSize=11; b.TextColor3=Color3.fromRGB(140,140,140)
    b.BackgroundColor3=Color3.fromRGB(35,35,45); b.Text=txt; b.Parent=tabRow
    Instance.new("UICorner",b).CornerRadius=UDim.new(0,6); return b
end
local hubTabBtn=mkTab("🏠 Hub"); hubTabBtn.TextColor3=Color3.fromRGB(255,255,255); hubTabBtn.BackgroundColor3=Color3.fromRGB(80,55,130)
local nukerTabBtn=mkTab("💥 Nuker")
local worldTabBtn=mkTab("🌎 World")
local boxesTabBtn=mkTab("📦 Boxes")
local settingsTabBtn=mkTab("⚙️ Settings")

local contentY=76

-- forward declarations for widgets referenced in background loops (made global to avoid Luau 200 local register limit)
hubPanel, nukerPanel, worldPanel, settingsPanel, boxesPanel = nil, nil, nil, nil, nil
idleBtn = nil
areaLbl, modeLbl, btLbl, fsLbl, psLbl, jfLbl, weightLbl, hpLbl, nextLbl, etaLbl, stLbl, arLbl = nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
fusStatLbl, fusReqLbl, fusPctLbl, fusRateLbl, fusEtaLbl = nil, nil, nil, nil, nil
sphereLabel, priorityLabel, statusLabel, mathLabel, errorLabel, startBtn = nil, nil, nil, nil, nil, nil

-- HUB PANEL
do
hubPanel=Instance.new("Frame")
hubPanel.Size=UDim2.new(1,0,1,-contentY); hubPanel.Position=UDim2.new(0,0,0,contentY)
hubPanel.BackgroundTransparency=1; hubPanel.Parent=mainFrame

local dz=Color3.fromRGB(145,138,160)

function mkHL(y,h,txt,col,align,bold)
    local l=Instance.new("TextLabel"); l.Size=UDim2.new(1,-pad*2,0,h); l.Position=UDim2.new(0,pad,0,y)
    l.BackgroundTransparency=1; l.Font=bold and Enum.Font.GothamBold or Enum.Font.Gotham
    l.TextSize=bold and 13 or 11; l.TextColor3=col; l.Text=txt
    l.TextXAlignment=align or Enum.TextXAlignment.Left; l.Parent=hubPanel; return l
end

function mkHBtn(x,w,y,h)
    local b=Instance.new("TextButton"); b.Size=UDim2.new(0,w,0,h); b.Position=UDim2.new(0,x,0,y)
    b.BorderSizePixel=0; b.Font=Enum.Font.GothamBold; b.TextSize=10; b.TextColor3=Color3.fromRGB(255,255,255); b.Parent=hubPanel
    Instance.new("UICorner",b).CornerRadius=UDim.new(0,7); return b
end

local btnW = math.floor((iw - 12) / 4)
local btBtn = mkHBtn(pad,              btnW, 6, 32)
local fsBtn = mkHBtn(pad+btnW+4,       btnW, 6, 32)
local psBtn = mkHBtn(pad+btnW*2+8,     btnW, 6, 32)
local jfBtn = mkHBtn(pad+btnW*3+12,    btnW, 6, 32)
local arBtn=mkHBtn(pad, math.floor(iw/2)-2, 42, 28)
local tpBackBtn=mkHBtn(pad+math.floor(iw/2)+2, math.floor(iw/2)-2, 42, 28)
local aqBtn=mkHBtn(pad, iw, 76, 28)
local halfW = math.floor((iw - 4) / 2)
local fsClickBtn=mkHBtn(pad, halfW, 108, 28)
local aeBtn=mkHBtn(pad+halfW+4, halfW, 108, 28)

local hubDiv=Instance.new("Frame"); hubDiv.Size=UDim2.new(1,-20,0,1); hubDiv.Position=UDim2.new(0,pad,0,140)
hubDiv.BackgroundColor3=Color3.fromRGB(55,45,75); hubDiv.BorderSizePixel=0; hubDiv.Parent=hubPanel

areaLbl  = mkHL(145, 18, "🪐 Trainer: off",       dz)
modeLbl  = mkHL(163, 18, "⚙️ Mode: ---",           dz)
btLbl    = mkHL(181, 18, "🛡️ BT: ...",             Color3.fromRGB(255,140,50))
fsLbl    = mkHL(199, 18, "🥊 FS: ...",             Color3.fromRGB(100,180,255))
psLbl    = mkHL(217, 18, "🧠 PS: ...",             Color3.fromRGB(200,100,255))
jfLbl    = mkHL(235, 18, "⚡ JF: ...",             Color3.fromRGB(80,220,120))
weightLbl= mkHL(253, 18, "🏋️ Weight: ---",          Color3.fromRGB(180,220,100))
hpLbl    = mkHL(271, 18, "❤️ HP: ...",             dz)
nextLbl  = mkHL(289, 18, "🔑 Next zone: ---",      Color3.fromRGB(170,160,200))
etaLbl   = mkHL(307, 18, "⏳ ETA: ---",            Color3.fromRGB(130,110,180))
stLbl    = mkHL(325, 18, "📈 Status: idle",        Color3.fromRGB(170,160,190))
arLbl    = mkHL(343, 18, "🔄 AutoRespawn: on",     Color3.fromRGB(90,200,255))

local fusDivider=Instance.new("Frame"); fusDivider.Size=UDim2.new(1,-20,0,1); fusDivider.Position=UDim2.new(0,pad,0,367)
fusDivider.BackgroundColor3=Color3.fromRGB(80,50,120); fusDivider.BorderSizePixel=0; fusDivider.Parent=hubPanel

mkHL(373,14,"⭐ FUSION TRACKER",Color3.fromRGB(200,160,255),nil,true)
fusStatLbl=mkHL(391,18,"🌌 TP:  ---  [?]",  Color3.fromRGB(255,200,80))
fusReqLbl =mkHL(409,18,"✨ Next: ---",       Color3.fromRGB(200,170,255))
fusPctLbl =mkHL(427,18,"📊 Progress: ---",   Color3.fromRGB(100,220,100))
fusRateLbl=mkHL(445,18,"📈 Rate:  ---",       Color3.fromRGB(160,200,255))
fusEtaLbl =mkHL(463,22,"⏳ ETA:   ---",       Color3.fromRGB(120,240,255),nil,true)
mkHL(499,14,"🪐 Antigravity | BT:"..#btAreas.."  FS:"..#fsAreas.."  PS:"..#psAreas.." zones",Color3.fromRGB(70,60,100),Enum.TextXAlignment.Center)

local trainerBtns = {BT=btBtn, FS=fsBtn, PS=psBtn, JF=jfBtn}
local trainerLabels = {BT="🛡️ BT", FS="🥊 FS", PS="🧠 PS", JF="⚡ JF"}

local trainerColors = {
    JF = Color3.fromRGB(20,130,60),
    BT = Color3.fromRGB(38,105,42),
    FS = Color3.fromRGB(30,90,160),
    PS = Color3.fromRGB(110,40,160),
}

local function refreshTrainerBtns()
    for key, btn in pairs(trainerBtns) do
        local on = (key == "JF") and (_G.JFEnabled == true) or (_G.ActiveTrainer == key)
        btn.Text = trainerLabels[key] .. ": " .. (on and "ON" or "OFF")
        TweenService:Create(btn,TweenInfo.new(0.15),{BackgroundColor3=on and trainerColors[key] or Color3.fromRGB(52,52,62)}):Play()
    end
end

local _EquipItem   = game:GetService("ReplicatedStorage").RemoteEvents.EquipItem
local _UnequipItem = game:GetService("ReplicatedStorage").RemoteEvents.UnequipItem

local _invCounts   = {}
local _invEquipped = {}
local _invMeta     = {}
local RARITY_RANK  = {Common=1,Rare=2,Epic=3,Legendary=4,Secret=5,Godly=6}
local TRAINER_STAT = {BT="BodyToughness", FS="FistStrength", PS="PsychicPower"}
local UNIVERSAL_ITEMS = {AncientStar=true, BlackHole=true}
local _lastBestId  = {} -- key -> last best item id chosen for that trainer

local function isUniversal(id)
    return id and UNIVERSAL_ITEMS[id] == true
end

-- Returns a list of owned item ids that boost statKey, ranked best-to-worst
-- by their boost value. Only includes items with count > 0.
local function getRankedForStat(statKey)
    local ranked = {}
    for id, count in pairs(_invCounts) do
        if count and count > 0 then
            local meta = _invMeta[id]
            if meta and meta.statBoosts then
                for boostKey, val in pairs(meta.statBoosts) do
                    if boostKey:find(statKey) then
                        table.insert(ranked, {id=id, value=tonumber(val) or 0})
                        break
                    end
                end
            end
        end
    end
    table.sort(ranked, function(a,b) return a.value > b.value end)
    return ranked
end

local function getBestForStat(statKey)
    local ranked = getRankedForStat(statKey)
    return ranked[1] and ranked[1].id or nil
end

-- Equips up to 3 of the best owned items for the active trainer's stat
-- (1 if you only own 1, 2 if you own 2, 3 if you own 3+), filling all
-- available slots. Universal items already equipped are left alone and
-- count toward the 3-slot cap.
local function autoEquipForTrainer(key)
    if not _G.AutoEquipEnabled then return end
    local statKey = TRAINER_STAT[key]
    if not statKey then return end
    task.spawn(function()
        local ranked = getRankedForStat(statKey)
        _lastBestId[key] = ranked[1] and ranked[1].id or nil

        -- figure out how many slots are free for stat items (reserve slots
        -- already taken by universal items)
        local universalEquipped = 0
        for id in pairs(_invEquipped) do
            if isUniversal(id) then universalEquipped += 1 end
        end
        local maxSlots = 3
        local statSlots = math.max(0, maxSlots - universalEquipped)

        -- desired set: top N ranked items for this stat (N = statSlots)
        local desired = {}
        for i = 1, math.min(statSlots, #ranked) do
            desired[ranked[i].id] = true
        end

        -- unequip anything that isn't universal and isn't in the desired set
        for id in pairs(_invEquipped) do
            if not isUniversal(id) and not desired[id] then
                _UnequipItem:FireServer(id); task.wait(0.08)
            end
        end

        -- equip everything in the desired set that isn't already equipped
        for id in pairs(desired) do
            if not _invEquipped[id] then
                _EquipItem:FireServer(id); task.wait(0.08)
            end
        end
    end)
end

-- Smart re-check: only re-equips when the inventory update actually changes
-- the best-ranked item for the currently active trainer's stat. No polling/
-- timers -- runs only when the server pushes a LoadInventory update.
local function maybeReEquip()
    if not _G.AutoEquipEnabled then return end
    local key = _G.ActiveTrainer
    local statKey = key and TRAINER_STAT[key]
    if not statKey then return end -- no trainer active, or JF (no stat item)

    local best = getBestForStat(statKey)
    if best == _lastBestId[key] then return end -- nothing changed, skip

    autoEquipForTrainer(key)
end

RemoteEvents.LoadInventory.OnClientEvent:Connect(function(counts, equipped, meta)
    _invCounts   = counts   or {}
    _invEquipped = equipped or {}
    _invMeta     = meta     or {}
    maybeReEquip()
end)
RemoteEvents.EquipItem:FireServer("__REQUEST_INVENTORY__")

local function setTrainer(key)
    if key == "JF" then
        _G.JFEnabled = not _G.JFEnabled
    else
        if _G.ActiveTrainer == key then
            _G.ActiveTrainer = nil
        else
            _G.ActiveTrainer = key
            autoEquipForTrainer(key)
        end
    end
    refreshTrainerBtns()
    saveSettings()
end

btBtn.MouseButton1Click:Connect(function() setTrainer("BT") end)
fsBtn.MouseButton1Click:Connect(function() setTrainer("FS") end)
psBtn.MouseButton1Click:Connect(function()
    if _G.JFEnabled then
        warn("[PS] Cannot switch to PS while JF is active! Disable JF first.")
        return
    end
    setTrainer("PS")
end)
jfBtn.MouseButton1Click:Connect(function()
    if _G.ActiveTrainer == "PS" and not _G.JFEnabled then
        warn("[JF] Cannot use JF with PS active!")
        return
    end
    setTrainer("JF")
end)

local function refreshARBtn()
    arBtn.Text="🔄 AR: "..(_G.AutoRespawnEnabled and "ON" or "OFF")
    arBtn.BackgroundColor3=_G.AutoRespawnEnabled and Color3.fromRGB(38,90,130) or Color3.fromRGB(52,52,62)
    arLbl.Text="🔄 AutoRespawn: "..(_G.AutoRespawnEnabled and "on" or "off")
    arLbl.TextColor3=_G.AutoRespawnEnabled and Color3.fromRGB(90,200,255) or Color3.fromRGB(150,150,150)
end
local function refreshTPBackBtn()
    tpBackBtn.Text="📍 TP Back: "..(_G.ARTeleportBack and "ON" or "OFF")
    tpBackBtn.BackgroundColor3=_G.ARTeleportBack and Color3.fromRGB(35,80,120) or Color3.fromRGB(45,45,55)
end
local function refreshAQBtn()
    aqBtn.Text="📜 Auto Quest: "..(_G.AutoQuestEnabled and "ON" or "OFF")
    aqBtn.BackgroundColor3=_G.AutoQuestEnabled and Color3.fromRGB(30,120,80) or Color3.fromRGB(45,45,55)
end
local function refreshFSClickBtn()
    fsClickBtn.Text="🥊 FS Auto Click: "..(fsAutoClick and "ON" or "OFF")
    fsClickBtn.BackgroundColor3=fsAutoClick and Color3.fromRGB(30,90,160) or Color3.fromRGB(45,45,55)
end
local function refreshAEBtn()
    aeBtn.Text="🎯 Equip Best (Auto): "..(_G.AutoEquipEnabled and "ON" or "OFF")
    aeBtn.BackgroundColor3=_G.AutoEquipEnabled and Color3.fromRGB(160,120,30) or Color3.fromRGB(45,45,55)
end

refreshTrainerBtns(); refreshARBtn(); refreshTPBackBtn(); refreshAQBtn(); refreshFSClickBtn(); refreshAEBtn()
aqBtn.MouseButton1Click:Connect(function() _G.AutoQuestEnabled=not _G.AutoQuestEnabled refreshAQBtn() saveSettings() end)
arBtn.MouseButton1Click:Connect(function() _G.AutoRespawnEnabled=not _G.AutoRespawnEnabled refreshARBtn() saveSettings() end)
tpBackBtn.MouseButton1Click:Connect(function() _G.ARTeleportBack=not _G.ARTeleportBack refreshTPBackBtn() saveSettings() end)
fsClickBtn.MouseButton1Click:Connect(function()
    fsAutoClick = not fsAutoClick
    refreshFSClickBtn()
    warn("[FSClick] Auto Click " .. (fsAutoClick and "ON" or "OFF"))
end)
aeBtn.MouseButton1Click:Connect(function()
    _G.AutoEquipEnabled = not _G.AutoEquipEnabled
    refreshAEBtn()
    saveSettings()
    warn("[AutoEquip] " .. (_G.AutoEquipEnabled and "ON" or "OFF"))
    if _G.AutoEquipEnabled and _G.ActiveTrainer then
        autoEquipForTrainer(_G.ActiveTrainer)
    end
end)
end -- HUB PANEL

-- NUKER PANEL
do
nukerPanel=Instance.new("Frame")
nukerPanel.Size=UDim2.new(1,0,1,-contentY); nukerPanel.Position=UDim2.new(0,0,0,contentY)
nukerPanel.BackgroundTransparency=1; nukerPanel.Visible=false; nukerPanel.Parent=mainFrame

function mkNL(y,h,txt,col,font,tsize,wrap)
    local l=Instance.new("TextLabel"); l.Size=UDim2.new(0,iw,0,h); l.Position=UDim2.new(0,pad,0,y)
    l.BackgroundTransparency=1; l.Font=font or Enum.Font.Gotham; l.TextSize=tsize or 12
    l.TextColor3=col or Color3.fromRGB(180,180,180); l.TextXAlignment=Enum.TextXAlignment.Left
    l.TextWrapped=wrap or false; l.Text=txt; l.Parent=nukerPanel; return l
end
function mkNH(y,txt)
    local l=Instance.new("TextLabel"); l.Size=UDim2.new(0,iw,0,12); l.Position=UDim2.new(0,pad,0,y)
    l.BackgroundTransparency=1; l.Font=Enum.Font.GothamBold; l.TextSize=10
    l.TextColor3=Color3.fromRGB(100,100,100); l.TextXAlignment=Enum.TextXAlignment.Left; l.Text=txt; l.Parent=nukerPanel
end

sphereLabel=mkNL(6,18,string.format("🔮 Sphere: %.1f  FS: %.2e",getSphereRadius(),LP:GetAttribute("FistStrength") or 0))
priorityLabel=mkNL(26,14,"🎯 Targeting: all",Color3.fromRGB(255,200,60),Enum.Font.Code,10)
statusLabel=mkNL(42,36,"📈 Status: Idle - press Start",Color3.fromRGB(150,150,150),Enum.Font.Gotham,12,true)
mathLabel=mkNL(80,18,"📏 Ray dist: --",Color3.fromRGB(100,200,100),Enum.Font.Code,11)
errorLabel=mkNL(100,14,"",Color3.fromRGB(255,80,80),Enum.Font.Code,10)

mkNH(120,"TARGETS")
local toggleRow=Instance.new("Frame"); toggleRow.Size=UDim2.new(0,iw,0,32); toggleRow.Position=UDim2.new(0,pad,0,134)
toggleRow.BackgroundTransparency=1; toggleRow.Parent=nukerPanel
local tLayout=Instance.new("UIListLayout"); tLayout.FillDirection=Enum.FillDirection.Horizontal; tLayout.SortOrder=Enum.SortOrder.LayoutOrder; tLayout.Padding=UDim.new(0,4); tLayout.Parent=toggleRow

local function updateToggleColor(btn,name)
    local on=enabledTargets[name]
    TweenService:Create(btn,TweenInfo.new(0.15),{BackgroundColor3=on and Color3.fromRGB(40,160,80) or Color3.fromRGB(55,55,55)}):Play()
    btn.TextColor3=on and Color3.fromRGB(255,255,255) or Color3.fromRGB(110,110,110)
end
for i,name in ipairs({"Noob","Thug","Mafia","WereWolf","Robot","Sath","Phantom"}) do
    local tb=Instance.new("TextButton"); tb.Size=UDim2.new(0,math.floor((iw-24)/7),1,0); tb.BackgroundColor3=Color3.fromRGB(55,55,55)
    tb.BorderSizePixel=0; tb.Font=Enum.Font.GothamBold; tb.TextSize=9; tb.Text=name; tb.LayoutOrder=i; tb.Parent=toggleRow
    Instance.new("UICorner",tb).CornerRadius=UDim.new(0,5); updateToggleColor(tb,name); toggleButtons[name]=tb
    tb.MouseButton1Click:Connect(function() enabledTargets[name]=not enabledTargets[name] manualTargets[name]=enabledTargets[name] updateToggleColor(tb,name) saveSettings() end)
end

mkNH(174,"MODE")
local modeRow=Instance.new("Frame"); modeRow.Size=UDim2.new(0,iw,0,32); modeRow.Position=UDim2.new(0,pad,0,188)
modeRow.BackgroundTransparency=1; modeRow.Parent=nukerPanel
local mLayout=Instance.new("UIListLayout"); mLayout.FillDirection=Enum.FillDirection.Horizontal; mLayout.SortOrder=Enum.SortOrder.LayoutOrder; mLayout.Padding=UDim.new(0,6); mLayout.Parent=modeRow
local tpBtn=Instance.new("TextButton"); tpBtn.Size=UDim2.new(0,math.floor(iw/2)-3,1,0); tpBtn.BorderSizePixel=0; tpBtn.Font=Enum.Font.GothamBold; tpBtn.TextSize=11; tpBtn.Text="📍 Teleport"; tpBtn.LayoutOrder=1; tpBtn.Parent=modeRow; Instance.new("UICorner",tpBtn).CornerRadius=UDim.new(0,5)
local fmBtn=Instance.new("TextButton"); fmBtn.Size=UDim2.new(0,math.floor(iw/2)-3,1,0); fmBtn.BorderSizePixel=0; fmBtn.Font=Enum.Font.GothamBold; fmBtn.TextSize=11; fmBtn.Text="🏃 Free Move"; fmBtn.LayoutOrder=2; fmBtn.Parent=modeRow; Instance.new("UICorner",fmBtn).CornerRadius=UDim.new(0,5)
local function refreshModeButtons()
    TweenService:Create(tpBtn,TweenInfo.new(0.15),{BackgroundColor3=teleportMode and Color3.fromRGB(55,115,210) or Color3.fromRGB(55,55,55)}):Play(); tpBtn.TextColor3=teleportMode and Color3.fromRGB(255,255,255) or Color3.fromRGB(110,110,110)
    TweenService:Create(fmBtn,TweenInfo.new(0.15),{BackgroundColor3=not teleportMode and Color3.fromRGB(55,115,210) or Color3.fromRGB(55,55,55)}):Play(); fmBtn.TextColor3=not teleportMode and Color3.fromRGB(255,255,255) or Color3.fromRGB(110,110,110)
end
refreshModeButtons()
tpBtn.MouseButton1Click:Connect(function() teleportMode=true refreshModeButtons() saveSettings() end)
fmBtn.MouseButton1Click:Connect(function() teleportMode=false refreshModeButtons() saveSettings() end)

mkNH(228,"PRIORITY TARGET")
local prioBtn=Instance.new("TextButton"); prioBtn.Size=UDim2.new(0,iw,0,28); prioBtn.Position=UDim2.new(0,pad,0,242); prioBtn.BorderSizePixel=0; prioBtn.Font=Enum.Font.GothamBold; prioBtn.TextSize=11; prioBtn.Text="🎯 Priority ON"; prioBtn.TextColor3=Color3.fromRGB(255,255,255); prioBtn.BackgroundColor3=Color3.fromRGB(180,130,20); prioBtn.Parent=nukerPanel; Instance.new("UICorner",prioBtn).CornerRadius=UDim.new(0,5)
prioBtn.MouseButton1Click:Connect(function()
    priorityMode=not priorityMode
    TweenService:Create(prioBtn,TweenInfo.new(0.15),{BackgroundColor3=priorityMode and Color3.fromRGB(180,130,20) or Color3.fromRGB(55,55,55)}):Play()
    prioBtn.TextColor3=priorityMode and Color3.fromRGB(255,255,255) or Color3.fromRGB(110,110,110); prioBtn.Text=priorityMode and "🎯 Priority ON" or "🎯 Priority OFF"
    saveSettings()
end)

mkNH(282,"AUTO-SKIP WEAK")
local skipBtn=Instance.new("TextButton"); skipBtn.Size=UDim2.new(0,iw,0,28); skipBtn.Position=UDim2.new(0,pad,0,298); skipBtn.BorderSizePixel=0; skipBtn.Font=Enum.Font.GothamBold; skipBtn.TextSize=11; skipBtn.Text="🚫 Active"; skipBtn.TextColor3=Color3.fromRGB(255,255,255); skipBtn.BackgroundColor3=Color3.fromRGB(40,160,80); skipBtn.Parent=nukerPanel; Instance.new("UICorner",skipBtn).CornerRadius=UDim.new(0,5)
skipBtn.MouseButton1Click:Connect(function()
    autoSkipWeak=not autoSkipWeak
    TweenService:Create(skipBtn,TweenInfo.new(0.15),{BackgroundColor3=autoSkipWeak and Color3.fromRGB(40,160,80) or Color3.fromRGB(55,55,55)}):Play()
    skipBtn.TextColor3=autoSkipWeak and Color3.fromRGB(255,255,255) or Color3.fromRGB(110,110,110); skipBtn.Text=autoSkipWeak and "🚫 Active" or "🚫 Off"
    saveSettings()
end)

do
    refreshModeButtons()
    prioBtn.BackgroundColor3=priorityMode and Color3.fromRGB(180,130,20) or Color3.fromRGB(55,55,55)
    prioBtn.TextColor3=priorityMode and Color3.fromRGB(255,255,255) or Color3.fromRGB(110,110,110)
    prioBtn.Text=priorityMode and "🎯 Priority ON" or "🎯 Priority OFF"
    skipBtn.BackgroundColor3=autoSkipWeak and Color3.fromRGB(40,160,80) or Color3.fromRGB(55,55,55)
    skipBtn.TextColor3=autoSkipWeak and Color3.fromRGB(255,255,255) or Color3.fromRGB(110,110,110)
    skipBtn.Text=autoSkipWeak and "🚫 Active" or "🚫 Off"
end
startBtn=Instance.new("TextButton"); startBtn.Size=UDim2.new(0,iw,0,34); startBtn.Position=UDim2.new(0,pad,0,334); startBtn.BackgroundColor3=Color3.fromRGB(40,180,80); startBtn.BorderSizePixel=0; startBtn.Font=Enum.Font.GothamBold; startBtn.TextSize=13; startBtn.TextColor3=Color3.fromRGB(255,255,255); startBtn.Text="🟢 Start"; startBtn.Parent=nukerPanel; Instance.new("UICorner",startBtn).CornerRadius=UDim.new(0,6)
if nukerRunning then
    _G.nukerRunning = true
    startBtn.Text="🔴 Stop"; TweenService:Create(startBtn,TweenInfo.new(0),{BackgroundColor3=Color3.fromRGB(200,50,50)}):Play()
    statusLabel.Text="🔎 Searching..."; statusLabel.TextColor3=Color3.fromRGB(255,200,50)
end
end -- NUKER PANEL

-- WORLD PANEL
do
worldPanel=Instance.new("Frame")
worldPanel.Size=UDim2.new(1,0,1,-contentY); worldPanel.Position=UDim2.new(0,0,0,contentY)
worldPanel.BackgroundTransparency=1; worldPanel.Visible=false; worldPanel.Parent=mainFrame

function mkWH(y,txt)
    local l=Instance.new("TextLabel"); l.Size=UDim2.new(0,iw,0,14); l.Position=UDim2.new(0,pad,0,y)
    l.BackgroundTransparency=1; l.Font=Enum.Font.GothamBold; l.TextSize=10
    l.TextColor3=Color3.fromRGB(100,100,100); l.TextXAlignment=Enum.TextXAlignment.Left
    l.Text=txt; l.Parent=worldPanel; return l
end
function mkWToggle(y,lbl)
    local b=Instance.new("TextButton"); b.Size=UDim2.new(0,iw,0,28); b.Position=UDim2.new(0,pad,0,y)
    b.BorderSizePixel=0; b.Font=Enum.Font.GothamBold; b.TextSize=11
    b.TextColor3=Color3.fromRGB(110,110,110); b.BackgroundColor3=Color3.fromRGB(55,55,55)
    b.Text=lbl; b.Parent=worldPanel; Instance.new("UICorner",b).CornerRadius=UDim.new(0,5); return b
end
function mkWL(y,txt,col)
    local l=Instance.new("TextLabel"); l.Size=UDim2.new(0,iw,0,16); l.Position=UDim2.new(0,pad,0,y)
    l.BackgroundTransparency=1; l.Font=Enum.Font.Gotham; l.TextSize=11
    l.TextColor3=col or Color3.fromRGB(180,180,180); l.TextXAlignment=Enum.TextXAlignment.Left
    l.Text=txt; l.Parent=worldPanel; return l
end

_G_FortLock = false
local _fortConn = nil

local function getFlagPrompt()
    local flag = workspace:FindFirstChild("Flag"); if not flag then return nil,nil end
    local fg = flag:FindFirstChild("Flag Group"); if not fg then return nil,nil end
    local fp = fg:FindFirstChild("FlagPole"); if not fp then return nil,nil end
    return flag, fp:FindFirstChildOfClass("ProximityPrompt")
end

function captureFlag()
    if _G.isCapturingFort then return end
    local flag, prompt = getFlagPrompt(); if not prompt then return end
    local hrp = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart"); if not hrp then return end
    _G.isCapturingFort = true
    local savedCF = hrp.CFrame
    warn("🏰 [Fort Lock] Capturing fort... Teleporting to FlagPole")
    pcall(function()
        hrp.AssemblyLinearVelocity = Vector3.new(0,0,0)
        hrp.AssemblyAngularVelocity = Vector3.new(0,0,0)
    end)
    prompt.HoldDuration = 0; prompt.MaxActivationDistance = 9999
    hrp.CFrame = prompt.Parent.CFrame * CFrame.new(0,0,3)
    task.wait(0.15)
    for i=1,5 do fireproximityprompt(prompt) end
    local t = tick()
    local isOwner = false
    repeat
        task.wait(0.05)
        local owner = flag:GetAttribute("OwnerName")
        local myGang = LP:GetAttribute("Gang")
        isOwner = (owner == LP.Name) or (myGang and myGang ~= "" and owner and string.find(owner, myGang, 1, true) ~= nil)
    until isOwner or tick()-t > 2
    hrp.CFrame = savedCF
    warn("🏰 [Fort Lock] Capture finished. Returned to starting position")
    pcall(function()
        hrp.AssemblyLinearVelocity = Vector3.new(0,0,0)
        hrp.AssemblyAngularVelocity = Vector3.new(0,0,0)
    end)
    _G.isCapturingFort = false
end

local fortLockBtn = mkWToggle(12,"🏰 Fort Lock: Off")

function _G.ToggleFortLock(val)
    if val == nil then val = not _G_FortLock end
    _G_FortLock = val
    TweenService:Create(fortLockBtn,TweenInfo.new(0.15),{BackgroundColor3=_G_FortLock and Color3.fromRGB(40,160,80) or Color3.fromRGB(55,55,55)}):Play()
    fortLockBtn.TextColor3 = _G_FortLock and Color3.fromRGB(255,255,255) or Color3.fromRGB(110,110,110)
    fortLockBtn.Text = _G_FortLock and "🏰 Fort Lock: On" or "🏰 Fort Lock: Off"
    if _G_FortLock then
        local flag = workspace:FindFirstChild("Flag")
        if flag then
            local owner = flag:GetAttribute("OwnerName")
            local myGang = LP:GetAttribute("Gang")
            local isOwner = (owner == LP.Name) or (myGang and myGang ~= "" and owner and string.find(owner, myGang, 1, true) ~= nil)
            if not isOwner and not _G.dtModeActive then captureFlag() end
        end
        if flag then
            _fortConn = track(flag:GetAttributeChangedSignal("OwnerName"):Connect(function()
                if not _G_FortLock then return end
                if _G.dtModeActive then return end
                local owner = flag:GetAttribute("OwnerName")
                local myGang = LP:GetAttribute("Gang")
                local isOwner = (owner == LP.Name) or (myGang and myGang ~= "" and owner and string.find(owner, myGang, 1, true) ~= nil)
                if not isOwner then
                    captureFlag()
                end
            end))
        end
    else
        if _fortConn then _fortConn:Disconnect(); _fortConn = nil end
    end
end

fortLockBtn.MouseButton1Click:Connect(function()
    _G.ToggleFortLock()
end)

local autoRollBtn = mkWToggle(48,"🎲 Auto Roll: Off")
local rollInfoLbl = mkWL(80,"🎟️ Tokens: -- | Last: --",Color3.fromRGB(140,140,160))

local _autoRoll = false
local _rollConn = nil

local function stopAutoRoll()
    _autoRoll = false
    _G.AutoRollEnabled = false
    if _rollConn then _rollConn:Disconnect(); _rollConn = nil end
    autoRollBtn.Text = "🎲 Auto Roll: Off"
    TweenService:Create(autoRollBtn,TweenInfo.new(0.15),{BackgroundColor3=Color3.fromRGB(55,55,55)}):Play()
    autoRollBtn.TextColor3 = Color3.fromRGB(110,110,110)
end

local function startAutoRoll()
    _autoRoll = true
    _G.AutoRollEnabled = true
    autoRollBtn.Text = "🎲 Auto Roll: ON"
    TweenService:Create(autoRollBtn,TweenInfo.new(0.15),{BackgroundColor3=Color3.fromRGB(40,120,60)}):Play()
    autoRollBtn.TextColor3 = Color3.fromRGB(255,255,255)
    local re = game:GetService("ReplicatedStorage").RemoteEvents
    task.spawn(function()
        while _autoRoll and hubAlive do
            local tokens = LP:GetAttribute("RollTokens") or 0
            if tokens <= 0 then
                stopAutoRoll()
                rollInfoLbl.Text = "🎟️ No tokens left"
                break
            end
            rollInfoLbl.Text = "🎟️ Tokens: "..tokens.." | 🎲 Rolling..."
            -- Connect BEFORE firing so fast server responses are never missed
            local result = nil
            _rollConn = re.RollRaceResult.OnClientEvent:Connect(function(ok, data)
                if ok and data then result = data end
            end)
            re.RollRace:FireServer()
            local t = tick()
            repeat task.wait() until result or tick()-t > 0.8
            if _rollConn then _rollConn:Disconnect(); _rollConn = nil end
            if result then
                local newTokens = LP:GetAttribute("RollTokens") or 0
                rollInfoLbl.Text = string.format("🎟️ Tokens: %d | Last: %s (x%.3f)", newTokens, tostring(result.Race), result.Multiplier or 0)
            end
        end
    end)
end

autoRollBtn.MouseButton1Click:Connect(function()
    if _autoRoll then stopAutoRoll() else startAutoRoll() end
    saveSettings()
end)

if _G.AutoRollEnabled then
    startAutoRoll()
end
end -- WORLD PANEL
-- BOXES PANEL
do
    boxesPanel=Instance.new("Frame")
    boxesPanel.Size=UDim2.new(1,0,1,-contentY)
    boxesPanel.Position=UDim2.new(0,0,0,contentY)
    boxesPanel.BackgroundTransparency=1
    boxesPanel.Visible=false
    boxesPanel.Parent=mainFrame

    local function mkBH(y,txt)
        local l=Instance.new("TextLabel")
        l.Size=UDim2.new(0,iw,0,14)
        l.Position=UDim2.new(0,pad,0,y)
        l.BackgroundTransparency=1
        l.Font=Enum.Font.GothamBold
        l.TextSize=10
        l.TextColor3=Color3.fromRGB(100,100,100)
        l.TextXAlignment=Enum.TextXAlignment.Left
        l.Text=txt
        l.Parent=boxesPanel
        return l
    end

    local function mkBL(txt,y)
        local l=Instance.new("TextLabel")
        l.Size=UDim2.new(1,-pad*2,0,20)
        l.Position=UDim2.new(0,pad,0,y)
        l.BackgroundTransparency=1
        l.Font=Enum.Font.GothamBold
        l.TextSize=14
        l.TextColor3=Color3.fromRGB(255,255,255)
        l.TextXAlignment=Enum.TextXAlignment.Left
        l.Text=txt
        l.Parent=boxesPanel
        return l
    end

    local BOX_TIER_ORDER = {"Tier1","Tier2","Tier3","Tier4"}
    local BOX_TIER_COST = {
        Tier1 = 1e12,
        Tier2 = 1e15,
        Tier3 = 1e18,
        Tier4 = 1e21,
    }

    mkBH(6, "AUTO BOX OPENER")

    local boxBtn=Instance.new("TextButton")
    boxBtn.Size=UDim2.new(0,iw,0,28)
    boxBtn.Position=UDim2.new(0,pad,0,22)
    boxBtn.BorderSizePixel=0
    boxBtn.Font=Enum.Font.GothamBold
    boxBtn.TextSize=13
    boxBtn.Text= _G.AutoBoxEnabled and "Auto Box Opener: ON" or "Auto Box Opener: OFF"
    boxBtn.BackgroundColor3= _G.AutoBoxEnabled and Color3.fromRGB(60,160,80) or Color3.fromRGB(160,60,60)
    boxBtn.TextColor3=Color3.fromRGB(255,255,255)
    boxBtn.Parent=boxesPanel
    Instance.new("UICorner",boxBtn).CornerRadius=UDim.new(0,5)
    boxBtn.MouseButton1Click:Connect(function()
        _G.AutoBoxEnabled = not _G.AutoBoxEnabled
        boxBtn.Text = _G.AutoBoxEnabled and "Auto Box Opener: ON" or "Auto Box Opener: OFF"
        boxBtn.BackgroundColor3 = _G.AutoBoxEnabled and Color3.fromRGB(60,160,80) or Color3.fromRGB(160,60,60)
        saveSettings()
    end)

    mkBH(60, "TIERS TO OPEN")

    local tierBtns = {}
    for i, tier in ipairs(BOX_TIER_ORDER) do
        local enabled = _G.AutoBoxTiers and _G.AutoBoxTiers[tier]
        if enabled == nil then enabled = true end
        if not _G.AutoBoxTiers then _G.AutoBoxTiers = {} end
        _G.AutoBoxTiers[tier] = enabled

        local bw=(iw-30)/4
        local tb=Instance.new("TextButton")
        tb.Size=UDim2.new(0,bw,0,26)
        tb.Position=UDim2.new(0,pad+(i-1)*(bw+10),0,76)
        tb.BorderSizePixel=0
        tb.Font=Enum.Font.GothamBold
        tb.TextSize=12
        tb.Text=tier
        tb.BackgroundColor3= enabled and Color3.fromRGB(60,160,80) or Color3.fromRGB(55,55,55)
        tb.TextColor3= enabled and Color3.fromRGB(255,255,255) or Color3.fromRGB(110,110,110)
        tb.Parent=boxesPanel
        Instance.new("UICorner",tb).CornerRadius=UDim.new(0,5)
        tb.MouseButton1Click:Connect(function()
            _G.AutoBoxTiers[tier] = not _G.AutoBoxTiers[tier]
            local on=_G.AutoBoxTiers[tier]
            tb.BackgroundColor3 = on and Color3.fromRGB(60,160,80) or Color3.fromRGB(55,55,55)
            tb.TextColor3 = on and Color3.fromRGB(255,255,255) or Color3.fromRGB(110,110,110)
            saveSettings()
        end)
        tierBtns[tier]=tb
    end

    mkBH(114, "OPEN INTERVAL")

    local speedLbl=Instance.new("TextLabel")
    speedLbl.Size=UDim2.new(0,50,0,16)
    speedLbl.Position=UDim2.new(1,-pad-50,0,112)
    speedLbl.BackgroundTransparency=1
    speedLbl.Font=Enum.Font.GothamBold
    speedLbl.TextSize=11
    speedLbl.TextColor3=Color3.fromRGB(255,255,255)
    speedLbl.TextXAlignment=Enum.TextXAlignment.Right
    if not _G.AutoBoxInterval then _G.AutoBoxInterval = 0.05 end
    speedLbl.Text=string.format("%.2fs", _G.AutoBoxInterval)
    speedLbl.Parent=boxesPanel

    local sliderBg=Instance.new("Frame")
    sliderBg.Size=UDim2.new(1,-pad*2,0,6)
    sliderBg.Position=UDim2.new(0,pad,0,134)
    sliderBg.BackgroundColor3=Color3.fromRGB(55,55,55)
    sliderBg.BorderSizePixel=0
    sliderBg.Active=true
    sliderBg.Parent=boxesPanel
    Instance.new("UICorner",sliderBg).CornerRadius=UDim.new(1,0)

    local minI,maxI=0.05,5
    local function pctFromInterval(v) return math.clamp((v-minI)/(maxI-minI),0,1) end

    local sliderFill=Instance.new("Frame")
    sliderFill.Size=UDim2.new(pctFromInterval(_G.AutoBoxInterval),0,1,0)
    sliderFill.BackgroundColor3=Color3.fromRGB(120,90,200)
    sliderFill.BorderSizePixel=0
    sliderFill.Parent=sliderBg
    Instance.new("UICorner",sliderFill).CornerRadius=UDim.new(1,0)

    local sliderBtn=Instance.new("TextButton")
    sliderBtn.Size=UDim2.new(0,14,0,14)
    sliderBtn.AnchorPoint=Vector2.new(0.5,0.5)
    sliderBtn.Position=UDim2.new(pctFromInterval(_G.AutoBoxInterval),0,0.5,0)
    sliderBtn.BackgroundColor3=Color3.fromRGB(200,180,255)
    sliderBtn.BorderSizePixel=0
    sliderBtn.Text=""
    sliderBtn.Parent=sliderBg
    Instance.new("UICorner",sliderBtn).CornerRadius=UDim.new(1,0)

    local UIS = game:GetService("UserInputService")
    local function updateSliderFromX(x)
        local rel=(x - sliderBg.AbsolutePosition.X)/sliderBg.AbsoluteSize.X
        rel=math.clamp(rel,0,1)
        _G.AutoBoxInterval = minI + rel*(maxI-minI)
        sliderFill.Size=UDim2.new(rel,0,1,0)
        sliderBtn.Position=UDim2.new(rel,0,0.5,0)
        speedLbl.Text=string.format("%.2fs", _G.AutoBoxInterval)
    end
    sliderBtn.MouseButton1Down:Connect(function() draggingSlider=true end)
    sliderBtn.InputBegan:Connect(function(input)
        if input.UserInputType==Enum.UserInputType.Touch then draggingSlider=true end
    end)
    sliderBg.InputBegan:Connect(function(input)
        if input.UserInputType==Enum.UserInputType.Touch then
            draggingSlider=true
            updateSliderFromX(input.Position.X)
        end
    end)
    UIS.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            if draggingSlider then saveSettings() end
            draggingSlider=false
        end
    end)
    UIS.InputChanged:Connect(function(input)
        if not draggingSlider then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            updateSliderFromX(input.Position.X)
        end
    end)

    mkBH(154, "STATUS")
    local tokensLbl=mkBL("Tokens: --", 170)
    local targetLbl=mkBL("Targeting: --", 192)
    local lastDropLbl=mkBL("Last drop: --", 214)

    task.spawn(function()
        while hubAlive do
            if not _G.AutoBoxEnabled then task.wait(0.5); continue end
            local tokens = LP:GetAttribute("Tokens") or 0
            tokensLbl.Text = "Tokens: "..tostring(tokens)
            local target = nil
            for i=#BOX_TIER_ORDER,1,-1 do
                local tier = BOX_TIER_ORDER[i]
                if _G.AutoBoxTiers[tier] and tokens >= BOX_TIER_COST[tier] then
                    target = tier; break
                end
            end
            if target then
                targetLbl.Text = "Targeting: "..target
                RemoteEvents.OpenMysteryBox:FireServer(target)
            else
                targetLbl.Text = "Targeting: none affordable"
            end
            task.wait(_G.AutoBoxInterval or 0.05)
        end
    end)


    local _pg = LP.PlayerGui
    local function suppressBoxPopup(gui)
        gui.Enabled = false
        task.defer(function() if gui and gui.Parent then gui:Destroy() end end)
    end
    for _, c in ipairs(_pg:GetChildren()) do
        if c.Name == "MysteryBoxResultGui" then suppressBoxPopup(c) end
    end
    _pg.ChildAdded:Connect(function(child)
        if child.Name == "MysteryBoxResultGui" then
            suppressBoxPopup(child)
        end
    end)













    RemoteEvents.MysteryBoxResult.OnClientEvent:Connect(function(result)
        if result and result.name then
            lastDropLbl.Text = "Last drop: "..tostring(result.name).." ("..tostring(result.rarity)..")"
        end
    end)
end -- BOXES PANEL


-- SETTINGS PANEL
do
settingsPanel=Instance.new("Frame")
settingsPanel.Size=UDim2.new(1,0,1,-contentY); settingsPanel.Position=UDim2.new(0,0,0,contentY)
settingsPanel.BackgroundTransparency=1; settingsPanel.Visible=false; settingsPanel.Parent=mainFrame

function mkSL(y,h,txt,col,bold)
    local l=Instance.new("TextLabel"); l.Size=UDim2.new(0,iw,0,h); l.Position=UDim2.new(0,pad,0,y)
    l.BackgroundTransparency=1; l.Font=bold and Enum.Font.GothamBold or Enum.Font.Gotham
    l.TextSize=bold and 13 or 11; l.TextColor3=col or Color3.fromRGB(180,180,180)
    l.TextXAlignment=Enum.TextXAlignment.Left; l.Text=txt; l.Parent=settingsPanel; return l
end
function mkSBtn(y,h,txt,col)
    local b=Instance.new("TextButton"); b.Size=UDim2.new(0,iw,0,h); b.Position=UDim2.new(0,pad,0,y); b.Text=txt or "Button"
    b.BorderSizePixel=0; b.Font=Enum.Font.GothamBold; b.TextSize=11
    b.TextColor3=Color3.fromRGB(255,255,255); b.BackgroundColor3=col or Color3.fromRGB(55,55,55)
    b.Parent=settingsPanel; Instance.new("UICorner",b).CornerRadius=UDim.new(0,7); return b
end

local chars = "abcdefghijklmnopqrstuvwxyz0123456789"

local charsLen = #chars
local function randName(minL, maxL)
    local len = math.random(minL, maxL)
    local t = table.create(len)
    for i = 1, len do
        local idx = math.random(1, charsLen); t[i] = chars:sub(idx, idx)
    end
    return table.concat(t)
end
local spoofEnabled = false
local fakeName = ""
local fakeSquad = ""
local plNameLabel = nil
local plNameConn  = nil

local spoofHeader = mkSL(6, 16, "👤 USERNAME SPOOFER", Color3.fromRGB(200,160,255), true)
local spoofStatusLbl = mkSL(26, 18, "👤 Status: off", Color3.fromRGB(150,150,150))
local fakeNameLbl = mkSL(46, 18, "🎭 Fake name: ---", Color3.fromRGB(100,210,255))
local fakeSquadLbl = mkSL(64, 18, "🛡️ Fake squad: ---", Color3.fromRGB(100,255,180))

local spoofToggle = mkSBtn(88, 30, "Spoofer OFF", Color3.fromRGB(55,55,55))
local rerollBtn = mkSBtn(124, 30, "Reroll Names", Color3.fromRGB(50,80,130))
rerollBtn.Text = "Reroll Names"

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
        refs.leaderOriginal  = refs.leaderLabel and refs.leaderLabel.Text or ""
        refs.origSquad      = refs.gangLabel  and refs.gangLabel.Text:match("Squad : (.+)") or ""
        refs.origGangName   = refs.gangName   and refs.gangName.Text:match("Squad Name : (.+)") or ""
        refs.origNotice1    = refs.notice1    and refs.notice1.Text or ""
        refs.origNotice2    = refs.notice2    and refs.notice2.Text or ""
    end
    local char = LP.Character
    local head = char and char:FindFirstChild("Head")
    local bb = head and head:FindFirstChild("OverheadBillboard")
    if bb then
        refs.overheadName = bb:FindFirstChild("NameLabel")
        local gangFr = bb:FindFirstChild("Gang_Frame")
        refs.overheadGang = gangFr and gangFr:FindFirstChild("Gang_Txt")
    end
    if refs.overheadGang then
        refs.origOverheadG = refs.overheadGang.Text
    else
        refs.origOverheadG = ""
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
    if refs.gangLabel    then refs.gangLabel.Text    = "Squad : "      .. refs.origSquad    end
    if refs.gangName     then refs.gangName.Text     = "Squad Name : " .. refs.origGangName  end
    if refs.leaderLabel  then refs.leaderLabel.Text  = refs.leaderOriginal or "" end
    if refs.notice1      then refs.notice1.Text      = refs.origNotice1 end
    if refs.notice2      then refs.notice2.Text      = refs.origNotice2 end
    if refs.memberRows   then for _, row in ipairs(refs.memberRows) do row.label.Text = row.original end end
    if refs.overheadName then refs.overheadName.Text = LP.Name end
    if refs.overheadGang then refs.overheadGang.Text = refs.origOverheadG end
    if plNameLabel and plNameLabel.Parent then plNameLabel.Text = LP.DisplayName end
    if plNameConn then plNameConn:Disconnect(); plNameConn = nil end
    plNameLabel = nil
end
local function refreshSpoofUI()
    if spoofEnabled then
        spoofToggle.Text = "Spoofer ON"
        TweenService:Create(spoofToggle,TweenInfo.new(0.15),{BackgroundColor3=Color3.fromRGB(40,160,80)}):Play()
        spoofStatusLbl.Text = "👤 Status: active"
        spoofStatusLbl.TextColor3 = Color3.fromRGB(90,210,90)
    else
        spoofToggle.Text = "Spoofer OFF"
        TweenService:Create(spoofToggle,TweenInfo.new(0.15),{BackgroundColor3=Color3.fromRGB(55,55,55)}):Play()
        spoofStatusLbl.Text = "👤 Status: off"
        spoofStatusLbl.TextColor3 = Color3.fromRGB(150,150,150)
    end
    fakeNameLbl.Text = "🎭 Fake name: " .. (spoofEnabled and fakeName or "---")
    fakeSquadLbl.Text = "🛡️ Fake squad: " .. (spoofEnabled and fakeSquad or "---")
end

spoofToggle.MouseButton1Click:Connect(function()
    spoofEnabled = not spoofEnabled
    if spoofEnabled then
        fakeName = randName(5, 10)
        fakeSquad = randName(5, 10)
        spoofRefs = buildSpoofRefs()
        applySpoof(spoofRefs)
        local pl = game:GetService("CoreGui"):FindFirstChild("PlayerList")
        if pl then
            for _, v in ipairs(pl:GetDescendants()) do
                if v:IsA("TextLabel") and v.Name == "PlayerName" and v.Text == LP.DisplayName then
                    plNameLabel = v
                    v.Text = fakeName
                    if plNameConn then plNameConn:Disconnect() end
                    plNameConn = track(v:GetPropertyChangedSignal("Text"):Connect(function()
                        if spoofEnabled and v.Text ~= fakeName then v.Text = fakeName end
                    end))
                    break
                end
            end
        end
        if spoofRefs then
            spoofRefs.conns = {}
            local function hookLabel(lbl, getter)
                if not lbl then return end
                table.insert(spoofRefs.conns, track(lbl:GetPropertyChangedSignal("Text"):Connect(function()
                    if spoofEnabled then local v = getter() if lbl.Text ~= v then lbl.Text = v end end
                end)))
            end
            hookLabel(spoofRefs.nameLabel,   function() return "Name : "       .. fakeName  end)
            hookLabel(spoofRefs.gangLabel,    function() return "Squad : "      .. fakeSquad end)
            hookLabel(spoofRefs.gangName,     function() return "Squad Name : " .. fakeSquad end)
            hookLabel(spoofRefs.leaderLabel,  function() return "Leader : "     .. (spoofRefs.memberRows and spoofRefs.memberRows[1] and spoofRefs.memberRows[1].fake or fakeName) end)
            hookLabel(spoofRefs.notice1,      function() return "Welcome to "   .. fakeSquad .. "!" end)
            hookLabel(spoofRefs.notice2,      function() return "Welcome to "   .. fakeSquad .. "!" end)
            hookLabel(spoofRefs.overheadName, function() return fakeName end)
            hookLabel(spoofRefs.overheadGang, function() return "[Member] " .. fakeSquad end)
            if spoofRefs.memberRows then
                for _, row in ipairs(spoofRefs.memberRows) do
                    local r = row
                    hookLabel(r.label, function() return r.fake end)
                end
            end
        end
    else
        if spoofRefs and spoofRefs.conns then for _, c in ipairs(spoofRefs.conns) do c:Disconnect() end spoofRefs.conns = nil end
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

local antiIdleHeader = mkSL(180, 16, "ANTI-IDLE", Color3.fromRGB(150,200,255), true)
idleBtn = mkSBtn(200, 28, antiIdle and "Active" or "Off", antiIdle and Color3.fromRGB(40,160,80) or Color3.fromRGB(55,55,55))
idleBtn.TextColor3 = antiIdle and Color3.fromRGB(255,255,255) or Color3.fromRGB(110,110,110)
idleBtn.MouseButton1Click:Connect(function()
    antiIdle = not antiIdle
    TweenService:Create(idleBtn,TweenInfo.new(0.15),{BackgroundColor3=antiIdle and Color3.fromRGB(40,160,80) or Color3.fromRGB(55,55,55)}):Play()
    idleBtn.TextColor3 = antiIdle and Color3.fromRGB(255,255,255) or Color3.fromRGB(110,110,110)
    idleBtn.Text = antiIdle and "Active" or "Off"
    saveSettings()
end)
end -- SETTINGS PANEL

-- TAB SWITCHING
do
    function switchTab(tab)
        hubPanel.Visible=(tab=="hub"); nukerPanel.Visible=(tab=="nuker"); settingsPanel.Visible=(tab=="settings"); worldPanel.Visible=(tab=="world"); boxesPanel.Visible=(tab=="boxes")
        local tabs = {hub=hubTabBtn, nuker=nukerTabBtn, settings=settingsTabBtn, world=worldTabBtn, boxes=boxesTabBtn}
        for k,b in pairs(tabs) do
            local on=(k==tab)
            TweenService:Create(b,TweenInfo.new(0.15),{BackgroundColor3=on and Color3.fromRGB(80,55,130) or Color3.fromRGB(35,35,45)}):Play()
            b.TextColor3=on and Color3.fromRGB(255,255,255) or Color3.fromRGB(140,140,140)
        end
    end
    hubTabBtn.MouseButton1Click:Connect(function() switchTab("hub") end)
    nukerTabBtn.MouseButton1Click:Connect(function() switchTab("nuker") end)
    settingsTabBtn.MouseButton1Click:Connect(function() switchTab("settings") end)
    worldTabBtn.MouseButton1Click:Connect(function() switchTab("world") end)
    boxesTabBtn.MouseButton1Click:Connect(function() switchTab("boxes") end)
    switchTab("hub")
end

-- DRAG
do
    local dragging,dragStart,startPos
    titleBar.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then dragging=true;dragStart=i.Position;startPos=mainFrame.Position end end)
    titleBar.InputChanged:Connect(function(i) if dragging and (i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch) then local d=i.Position-dragStart; mainFrame.Position=UDim2.new(startPos.X.Scale,startPos.X.Offset+d.X,startPos.Y.Scale,startPos.Y.Offset+d.Y) end end)
    titleBar.InputEnded:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then dragging=false end end)
end

-- NUKER LOOP
startBtn.MouseButton1Click:Connect(function()
    nukerRunning = not nukerRunning
    _G.nukerRunning = nukerRunning
    saveSettings()
    if nukerRunning then
        startBtn.Text="🔴 Stop"; TweenService:Create(startBtn,TweenInfo.new(0.2),{BackgroundColor3=Color3.fromRGB(200,50,50)}):Play()
        statusLabel.Text="🔎 Searching..."; statusLabel.TextColor3=Color3.fromRGB(255,200,50)
    else
        startBtn.Text="🟢 Start"; TweenService:Create(startBtn,TweenInfo.new(0.2),{BackgroundColor3=Color3.fromRGB(40,180,80)}):Play()
        statusLabel.Text="📈 Status: Idle - press Start"; statusLabel.TextColor3=Color3.fromRGB(150,150,150)
        mathLabel.Text="📏 Ray dist: --"; errorLabel.Text=""; priorityLabel.Text="🎯 Targeting: all"
    end
end)
task.spawn(function()
    while hubAlive do
        if not nukerRunning or _G.isCapturingFort then task.wait(0.2); continue end
        if not character or not hrp or not hrp.Parent then statusLabel.Text="⏳ Waiting for character..."; task.wait(1); continue end
        local alive=getAlive()
        if #alive==0 then statusLabel.Text="⏳ Waiting for spawns..."; statusLabel.TextColor3=Color3.fromRGB(150,150,150); mathLabel.Text="📏 Ray dist: --"; priorityLabel.Text="🎯 Targeting: none"; task.wait(0.5); continue end
        local currentType=alive[1].name
        priorityLabel.Text=string.format("🎯 Targeting: %s (%.0e tk)",currentType,tokenValues[currentType] or 0)
        local radius=getSphereRadius(); sphereLabel.Text=string.format("🔮 Sphere: %.1f  FS: %.2e",radius,LP:GetAttribute("FistStrength") or 0)
        local ok,origin,dir,maxDist,centroid,hits=pcall(findBestLine,alive,radius); if not ok or not origin then task.wait(0.5); continue end

        errorLabel.Text=""
        statusLabel.Text=string.format("💥 Hitting %d / %d",hits,#alive); statusLabel.TextColor3=Color3.fromRGB(255,120,50)
        mathLabel.Text=string.format("📏 Max dev: %.2f / %.1f  %s",maxDist,radius,hits==#alive and "OK" or "!"); mathLabel.TextColor3=hits==#alive and Color3.fromRGB(100,220,100) or Color3.fromRGB(255,160,50)
        if teleportMode then hrp.CFrame=CFrame.new(origin,origin+dir); task.wait(0.05) end
        pcall(function() UseSkill:FireServer("EnergySphere",centroid+dir*behindDist) end)
        task.wait(burstSpeed)
    end
end)

-- WEIGHT DATA
weightData = {
    {title="100 LB",   req=100},
    {title="1 TON",    req=5000},
    {title="10 TON",   req=500000},
    {title="100 TON",  req=10000000},
    {title="1K TON",   req=100000000},
    {title="10K TON",  req=1000000000},
    {title="100K TON", req=10000000000},
    {title="1M TON",   req=100000000000},
    {title="10M TON",  req=1000000000000},
    {title="100M TON", req=10000000000000},
    {title="1B TON",   req=100000000000000},
    {title="10B TON",  req=1000000000000000},
}

local function getBestWeightIndex()
    local jf = tonumber(LP:GetAttribute("JumpForce")) or 0
    local best = 0
    for i, w in ipairs(weightData) do
        if jf >= w.req then best = i end
    end
    return best
end

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

        btLbl.Text=string.format("🛡️ BT: %s  (x%s  +%s/s)", fmtNum(bt), fmtNum(btM), fmtNum(btRate))
        fsLbl.Text=string.format("🥊 FS: %s  (x%s  +%s/s)", fmtNum(fs), fmtNum(fsM), fmtNum(fsRate))
        psLbl.Text=string.format("🧠 PS: %s  (x%s  +%s/s)", fmtNum(ps), fmtNum(psM), fmtNum(psRate))
        local jf  = tonumber(LP:GetAttribute("JumpForce")) or 0
        local jfM = LP:GetAttribute("JumpForceMultiplier") or 1
        local jp  = tonumber(LP:GetAttribute("JumpPower")) or 0
        jfLbl.Text  = string.format("⚡ JF: %s  (x%s)", fmtNum(jf), fmtNum(jfM))
        if _G.JFEnabled then
            local wi = getBestWeightIndex()
            local wt = wi > 0 and weightData[wi].title or "Unequipped"
            weightLbl.Text = "🏋️ Weight: " .. wt .. "  JF:" .. fmtNum(jf)
            weightLbl.TextColor3 = Color3.fromRGB(180,220,100)
        else
            weightLbl.Text = "🏋️ Weight: ---"
            weightLbl.TextColor3 = Color3.fromRGB(100,100,100)
        end

        local tp=tonumber(LP:GetAttribute("TotalPower")) or 0
        local fusionName=tostring(LP:GetAttribute("FusionName") or "?")
        local nextTier=getNextFusionTier(); recordFusion(tp); local fusRate2=getFusionRate()
        if nextTier then
            local req=nextTier.req; local remaining=math.max(0,req-tp)
            local pct=math.min(100,(tp/req)*100); local etaSecs=fusRate2>0 and (remaining/fusRate2) or math.huge
            fusStatLbl.Text=string.format("🌌 TP:  %s  [%s]",fmtNum(tp),fusionName)
            fusReqLbl.Text=string.format("✨ Next: %s  (%s req)",nextTier.name,fmtNum(req))
            fusPctLbl.Text=string.format("📊 Progress: %.4f%%",pct)
            fusRateLbl.Text=string.format("📈 Rate:  +%s/s",fmtNum(fusRate2))
            if fusRate2>0 then
                fusEtaLbl.Text="⏳ ETA:   "..fmtETALong(etaSecs); fusEtaLbl.TextColor3=Color3.fromRGB(120,240,255)
                local now=tick(); if now-lastFusionPrint>=60 then lastFusionPrint=now warn(string.format("[Fusion] TP=%.3e  %s->%s  ETA=%s",tp,fusionName,nextTier.name,fmtETALong(etaSecs))) end
            else fusEtaLbl.Text="⏳ ETA:   warming up..."; fusEtaLbl.TextColor3=Color3.fromRGB(150,150,150) end
        else
            fusStatLbl.Text=string.format("🌌 TP:  %s  [%s]",fmtNum(tp),fusionName); fusReqLbl.Text="✨ Next: ALL MAXED"; fusPctLbl.Text="📊 Progress: 100%"
            fusRateLbl.Text=string.format("📈 Rate:  +%s/s",fmtNum(fusRate2)); fusEtaLbl.Text="⏳ Maxed!"; fusEtaLbl.TextColor3=Color3.fromRGB(255,215,0)
        end

        local char=LP.Character; local hum=char and char:FindFirstChild("Humanoid"); local crp=char and char:FindFirstChild("HumanoidRootPart")
        if hum and hum.MaxHealth>0 then
            local pct=hum.Health/hum.MaxHealth
            hpLbl.Text=string.format("❤️ HP: %d%% (%d/%d)",math.floor(pct*100),math.floor(hum.Health),math.floor(hum.MaxHealth))
            hpLbl.TextColor3=pct>0.6 and Color3.fromRGB(90,210,90) or pct>0.25 and Color3.fromRGB(255,185,50) or Color3.fromRGB(255,60,60)
        else hpLbl.Text="❤️ HP: dead"; hpLbl.TextColor3=Color3.fromRGB(200,60,60) end

        local key=_G.ActiveTrainer
        if not key then
            _G.dtModeActive = false
            if activeArea then activeArea=nil; activeKey=nil end
            areaLbl.Text="🪐 Trainer: off"; areaLbl.TextColor3=Color3.fromRGB(145,138,160)
            modeLbl.Text="⚙️ Mode: ---"; modeLbl.TextColor3=Color3.fromRGB(145,138,160)
            stLbl.Text="📈 Status: idle"; stLbl.TextColor3=Color3.fromRGB(145,138,160)
            nextLbl.Text="🔑 Next zone: ---"; nextLbl.TextColor3=Color3.fromRGB(145,138,160); etaLbl.Text=""
            continue
        end

        if not crp or not hum or hum.Health<=0 then
            areaLbl.Text="🪐 Trainer: dead, waiting..."; areaLbl.TextColor3=Color3.fromRGB(180,180,180)
            stLbl.Text="📈 Status: respawning"; stLbl.TextColor3=Color3.fromRGB(180,180,180); continue
        end

        local cfg=trainerConfig[key]
        if not cfg or not cfg.areas then continue end
        local statVal=tonumber(LP:GetAttribute(cfg.stat)) or 0
        local statRate = key=="BT" and btRate or key=="FS" and fsRate or key=="PS" and psRate or 0

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

        if nextZone then
            local needed=(key == "BT" and nextZone.req/dtDivisor or nextZone.req) - statVal
            if needed<=0 then
                nextLbl.Text="🔑 Next: "..nextZone.name.." UNLOCKED"; nextLbl.TextColor3=Color3.fromRGB(90,210,90); etaLbl.Text=""
            else
                local eta=statRate>0 and (needed/statRate) or math.huge
                nextLbl.Text=string.format("🔑 Next: %s (need %s)",nextZone.name,fmtNum(key == "BT" and nextZone.req/dtDivisor or nextZone.req)); nextLbl.TextColor3=Color3.fromRGB(170,160,200)
                etaLbl.Text=string.format("⏳ ETA: %s  (+%s)",fmtTime(eta),fmtNum(needed)); etaLbl.TextColor3=Color3.fromRGB(130,110,180)
            end
        else nextLbl.Text="🔑 Next: ALL MAXED"; nextLbl.TextColor3=Color3.fromRGB(255,215,0); etaLbl.Text="" end

        if bestArea and (activeArea~=bestArea or activeKey~=key) then
            activeArea=bestArea; activeKey=key; _G.activeTrainArea=activeArea
            if not _G.isCapturingFort and not isInsideArea(crp.Position, activeArea) then
                stLbl.Text="📈 Status: teleporting to "..activeArea.name; stLbl.TextColor3=Color3.fromRGB(255,200,50)
                crp.CFrame = getAreaLandCFrame(activeArea)
            end
        end

        if not activeArea then
            areaLbl.Text="🪐 Trainer: no zone yet"; areaLbl.TextColor3=Color3.fromRGB(145,138,160)
            stLbl.Text="📈 Status: stat too low for any zone"; stLbl.TextColor3=Color3.fromRGB(145,138,160); continue
        end

        if not _G.isCapturingFort and not isInsideArea(crp.Position, activeArea) then
            crp.CFrame = getAreaLandCFrame(activeArea)
        end

        areaLbl.Text=string.format("🪐 Trainer: %s -> %s",key,activeArea.name); areaLbl.TextColor3=cfg.color
        if key ~= "BT" then
            _G.dtModeActive = false
            modeLbl.Text="⚙️ Mode: Grinding"; modeLbl.TextColor3=cfg.color
            stLbl.Text="📈 Status: grinding "..key.."..."; stLbl.TextColor3=cfg.color
        elseif statVal>=(activeArea.req*4) then
            _G.dtModeActive = false
            modeLbl.Text="⚙️ Mode: AFK (no damage)"; modeLbl.TextColor3=Color3.fromRGB(90,200,255)
            stLbl.Text="📈 Status: AFK grinding BT..."; stLbl.TextColor3=Color3.fromRGB(90,200,255)
        else
            _G.dtModeActive = true
            local pct=math.floor((statVal/(activeArea.req*4))*100)
            modeLbl.Text=string.format("⚙️ Mode: Death Train (%d%% to AFK)",pct); modeLbl.TextColor3=cfg.color
            stLbl.Text="📈 Status: dying for BT..."; stLbl.TextColor3=cfg.color
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
                    local completed = false
                    pcall(function() completed = qt.mod:Completed(LP, v, k2) end)
                    if completed then
                        timerQuestClaim:FireServer(k, k2, qt.label)
                        task.wait(0.3)
                    end
                end
            end
        end
    end
end)

-- FS AUTO CLICKER LOOP
task.spawn(function()
    while hubAlive do
        task.wait(fsClickInterval)
        if fsAutoClick and _G.ActiveTrainer == "FS" then
            pcall(function() FS_Train:FireServer() end)
        end
    end
end)

-- JF TRAINER LOOP
task.spawn(function()
    local jfConn = nil
    local lastWeightIdx = -1
    local UIS = game:GetService("UserInputService")

    local function doJump()
        if not _G.JFEnabled then return end
        VIM:SendKeyEvent(true,  Enum.KeyCode.Space, false, game)
        task.wait(0.05)
        VIM:SendKeyEvent(false, Enum.KeyCode.Space, false, game)
    end

    local function hookJF()
        if jfConn then jfConn:Disconnect(); jfConn = nil end
        local char = LP.Character or LP.CharacterAdded:Wait()
        local hum = char:WaitForChild("Humanoid", 10)
        if not hum then return end
        local lastState = hum:GetState()
        local newIdx = getBestWeightIndex()
        SetWeight:FireServer(newIdx)
        lastWeightIdx = newIdx
        local lastJumpTime = tick()
        warn(string.format("[JF] Started - weight: %s", newIdx > 0 and weightData[newIdx].title or "Unequipped"))
        jfConn = track(game:GetService("RunService").Heartbeat:Connect(function()
            if not _G.JFEnabled then lastState = hum:GetState(); return end
            local curIdx = getBestWeightIndex()
            if curIdx ~= lastWeightIdx then
                SetWeight:FireServer(curIdx)
                lastWeightIdx = curIdx
                warn(string.format("[JF] Weight upgraded: %s", curIdx > 0 and weightData[curIdx].title or "Unequipped"))
            end
            local state = hum:GetState()
            if state == Enum.HumanoidStateType.Landed and lastState ~= Enum.HumanoidStateType.Landed then
                JF_Train:FireServer()
                lastJumpTime = tick()
                task.delay(0.06, function() doJump() end)
            end
            local stateVal = typeof(state) == "number" and state or state.Value
            if stateVal == 14 and (tick() - lastJumpTime) > 1.5 then
                lastJumpTime = tick()
                JF_Train:FireServer()
                task.delay(0.06, function() doJump() end)
            end
            lastState = state
        end))
        task.delay(0.1, function() doJump() end)
    end

    track(UIS:GetPropertyChangedSignal("ModalEnabled"):Connect(function()
        if not _G.JFEnabled then return end
        if not UIS.ModalEnabled then
            task.delay(0.15, function() doJump() end)
        end
    end))

    local wasJF = false
    track(game:GetService("RunService").Heartbeat:Connect(function()
        local isJF = (_G.JFEnabled == true)
        if isJF and not wasJF then
            hookJF()
        elseif not isJF and wasJF then
            if jfConn then jfConn:Disconnect(); jfConn = nil end
            SetWeight:FireServer(0)
            lastWeightIdx = -1
            warn("[JF] Stopped - weight unequipped")
        end
        wasJF = isJF
    end))

    track(LP.CharacterAdded:Connect(function()
        task.wait(1.5)
        lastWeightIdx = -1
        if _G.JFEnabled then hookJF() end
    end))
end)
warn("[AG] Ready - BT:"..#btAreas.." FS:"..#fsAreas.." PS:"..#psAreas.." zones")
warn("[AutoRespawn] Active")
warn("[LineShotNuker] Ready")
warn("[FusionTracker] Active")
