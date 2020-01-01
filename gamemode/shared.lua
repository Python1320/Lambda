if SERVER then
    AddCSLuaFile()
end

GM.Name = "Lambda"
GM.Author = "N/A"
GM.Email = "N/A"
GM.Website = "https://github.com/ZehMatt/Lambda"
GM.Version = "0.9.10"

DEFINE_BASECLASS( "gamemode_base" )

include("sh_debug.lua")
include("sh_convars.lua")
include("sh_string_extend.lua")
include("sh_interpvalue.lua")
include("sh_timestamp.lua")
include("sh_gma.lua")

include("sh_surfaceproperties.lua")
include("sh_player_list.lua")
include("sh_mapdata.lua")
include("sh_utils.lua")
include("sh_ents_extend.lua")
include("sh_npc_extend.lua")
include("sh_player_extend.lua")
include("sh_entity_extend.lua")
include("sh_weapon_extend.lua")
include("sh_roundsystem.lua")
include("sh_sound_env.lua")
include("sh_vehicles.lua")
include("sh_sound_env.lua")
include("sh_temp.lua")
include("sh_bullets.lua")
include("sh_hudhint.lua")

include("sh_lambda.lua")
include("sh_lambda_npc.lua")
include("sh_lambda_player.lua")
include("sh_difficulty.lua")
include("sh_animations.lua")
include("sh_spectate.lua")
include("sh_playermodels.lua")
include("sh_globalstate.lua")
include("sh_userauth.lua")
include("sh_settings.lua")
include("sh_admin_config.lua")
include("sh_voting.lua")
include("sh_metrics.lua")
include("sh_maplist.lua")

include("sh_gametypes.lua")

local DbgPrint = GetLogging("Shared")

function GM:Tick()

    if CLIENT then
        self:HUDTick()
    else
        self:UpdateCheckoints()
    end

    if SERVER then
        self:UpdateItemRespawn()
        self:CheckPlayerTimeouts()
        self:RoundThink()
        self:VehiclesThink()
        self:NPCThink()
        self:WeaponTrackingThink()
        self:CheckStuckScenes()
        self:UpdateVotes()
    else
        self:ClientThink()
    end

    if self.MapScript and self.MapScript.Think then
        self.MapScript:Think()
    end

    -- Make sure physics don't go crazy when we toggle it.
    local collisionChanged = false
    if self.LastAllowCollisions ~= self:GetSetting("playercollision") then
        collisionChanged = true
        self.LastAllowCollisions = self:GetSetting("playercollision")
    end

    local plys = player.GetAll()
    for _,v in pairs(plys) do
        self:PlayerThink(v)
        if collisionChanged == true then
            v:CollisionRulesChanged()
        end
    end

    if SERVER then
        while #plys > 0 do
            local i = math.random(1, #plys)
            local v = plys[i]
            table.remove(plys, i)
            self:UpdatePlayerSpeech(v)
        end
    end

    local gameType = self:GetGameType()
    if gameType.Think then
        gameType:Think()
    end

end

function GM:EntityRemoved(ent)
    -- HACK: Fix fire sounds never stopping if packet loss happened, we just force it to stop on deletion.
    ent:StopSound("General.BurningFlesh")
    ent:StopSound("General.BurningObject")

    local class = ent:GetClass()
    if class == "logic_choreographed_scene" and self.LogicChoreographedScenes ~= nil then
        self.LogicChoreographedScenes[ent] = nil
    end
end

-- NOTE: This case is probably fixed, this was due to an uninitialized variable
--       which Willox fixed, revisit this.
function GM:CheckStuckScenes()

    local curTime = CurTime()
    if self.LastStuckScenesCheck ~= nil and curTime - self.LastStuckScenesCheck < 0.5 then
        return
    end
    self.LastStuckScenesCheck = curTime

    for ent,_ in pairs(self.LogicChoreographedScenes or {}) do

        if not IsValid(ent) then
            table.remove(self.LogicChoreographedScenes, ent)
            continue
        end

        local waitingForActor = ent:GetInternalVariable("m_bWaitingForActor", false)
        if waitingForActor == true then
            if ent.WaitingForActor ~= true then
                DbgPrint(ent, "now waiting for actor")
                ent.WaitingForActorTime = CurTime()
                ent.WaitingForActor = true
            elseif ent.WaitingForActor == true then
                local delta = CurTime() - ent.WaitingForActorTime
                if delta >= 5 then
                    DbgPrint("Long waiting logic_choreographed_scene")
                    ent:SetKeyValue("busyactor", "0")
                    ent.WaitingForActor = false
                end
            end
        else
            if ent.WaitingForActor == true then
                DbgPrint(ent, "no longer waiting")
            end
            ent.WaitingForActor = false
        end

    end

end

function GM:OnGamemodeLoaded()

    DbgPrint("GM:OnGamemodeLoaded")

    self.ServerStartupTime = GetSyncedTimestamp()

    self:LoadGameTypes()
    self:SetGameType(lambda_gametype:GetString())
    self:InitSettings()
    self:MountRequiredContent()

end

function GM:OnReloaded()

    DbgPrint("GM:OnReloaded")

    if CLIENT then
        self:HUDInit(true)
    end

    self:LoadGameTypes()
    self:SetGameType(lambda_gametype:GetString())
    self:InitSettings()
end

function GM:MountRequiredContent()

    local gametype = self:GetGameType()
    local filename = "lambda_mount_" .. gametype.GameType .. ".dat"
    local mountFiles = gametype.MountContent or {}

    if table.Count(mountFiles) == 0 then
        return true
    end

    if file.Exists(filename, "DATA") == false then
        DbgPrint("Creating new GMA mount package...")
        if GMA.CreatePackage(mountFiles, filename) == false then
            DbgPrint("Unable to create GMA archive, make sure you have the required content mounted.")
            return
        end
        DbgPrint("OK.")
    else
        DbgPrint("Found pre-existing GMA archive, no need to generate.")
    end

    if file.Exists(filename, "DATA") == false then
        -- What?
        DbgPrint("Unable to find the GMA archive, unable to mount.")
        return
    end

    local res, _ = game.MountGMA("data/" .. filename)
    if res == false then
        DbgPrint("Unable to mount the required GMA, you may be unable to play.")
        return
    end

    DbgPrint("Mounted content!")

end

function GM:Initialize()

    DbgPrint("GM:Initialize")
    DbgPrint("Synced Timestamp: " .. GetSyncedTimestamp())

    self:InitializePlayerList()
    self:InitializeRoundSystem()

    if SERVER then
        self:ResetSceneCheck()
        self:ResetPlayerRespawnQueue()
        self:InitializeItemRespawn()
        self:InitializeGlobalSpeechContext()
        self:InitializeWeaponTracking()
        self:InitializeGlobalStates()
        self:InitializePlayerModels()
        self:InitializeDifficulty()
        if self.InitializeSkybox then
            self:InitializeSkybox()
        end
        self:InitializeCurrentLevel()
        self:TransferPlayers()
        self:InitializeResources()
    end
end

function GM:ResetSceneCheck()
    self.LogicChoreographedScenes = {}
    self.LastStuckScenesCheck = CurTime()
end

function GM:InitPostEntity()

    DbgPrint("GM:InitPostEntity")

    if SERVER then
        self:ResetGlobalStates()
        self:PostLoadTransitionData()
        self:InitializeMapVehicles()
        if self.PostInitializeSkybox then
            self:PostInitializeSkybox()
        end
        self:SetRoundBootingComplete()
        self.InitPostEntityDone = true

        util.RunNextFrame(function()
            if self.MapScript.LevelPostInit ~= nil then
                self.MapScript:LevelPostInit()
            end
        end)

    else
        self:HUDInit()
    end

end

function GM:ShouldCollide(ent1, ent2)

    if ent1:IsPlayer() and ent2:IsPlayer() then
        if self:GetSetting("playercollision") == false then
            return false
        end
        if ent1:GetNWBool("DisablePlayerCollide", false) == true or ent2:GetNWBool("DisablePlayerCollide", false) == true then
            return false
        end
    elseif (ent1:IsNPC() and ent2:GetClass() == "trigger_changelevel") or
       (ent2:IsNPC() and ent1:GetClass() == "trigger_changelevel")
    then
        return false
    end

    -- Nothing collides with blocked triggers except players.
    if ent1.IsLambdaTrigger ~= nil and ent1:IsLambdaTrigger() == true then
        if ent2:IsPlayer() == true or ent2:IsVehicle() == true then
            return ent1:IsBlocked()
        end
        return false
    elseif ent2.IsLambdaTrigger ~= nil and ent2:IsLambdaTrigger() == true then
        if ent1:IsPlayer() == true or ent1:IsVehicle() == true then
            return ent2:IsBlocked()
        end
        return false
    end

    return true

end

function GM:ProcessEnvHudHint(ent)
    DbgPrint(ent, "Enabling env_hudhint for all players")
    ent:AddSpawnFlags(1) -- SF_HUDHINT_ALLPLAYERS
end

function GM:ProcessEnvMessage(ent)
    DbgPrint(ent, "Enabling env_message for all players")
    ent:AddSpawnFlags(2) -- SF_MESSAGE_ALL
end

function GM:ProcessFuncAreaPortal(ent)
    DbgPrint(ent, "Opening func_areaportal")
    -- TODO: This is not ideal at all on larger maps, however can can not get a position for them.
    ent:SetKeyValue("StartOpen", "1")
    ent:Fire("Open")
    ent:SetName("Lambda_" .. ent:GetName())
end

function GM:ProcessFuncAreaPortalWindow(ent)
    DbgPrint(ent, "Extending func_areaportalwindow")
    -- I know this is ugly, but its better than white windows everywhere, this is not 2004 anymore.
    local saveTable = ent:GetSaveTable()
    local fadeStartDist = tonumber(saveTable["FadeStartDist"] or "0") * 3
    local fadeDist = tonumber(saveTable["FadeDist"] or "0") * 3
    ent:SetKeyValue("FadeDist", fadeDist)
    ent:SetKeyValue("FadeStartDist", fadeStartDist)
end

function GM:ProcessTriggerWeaponDissolve(ent)
    -- OnChargingPhyscannon
    -- UGLY HACK! But thats the only way we can tell when to upgrade.
    ent:Fire("AddOutput", "OnChargingPhyscannon lambda_physcannon,Supercharge,,0")
end

function GM:ProcessLogicChoreographedScene(ent)

    self.LogicChoreographedScenes = self.LogicChoreographedScenes or {}
    self.LogicChoreographedScenes[ent] = true

end

-- HACKHACK: We assign the next path_track on the activator for transition data.
function GM:ProcessPathTrackHack(ent)
    local tracker = self.PathTracker
    if not IsValid(tracker) then
        tracker = ents.Create("lambda_path_tracker")
        tracker:SetName("lambda_path_tracker")
        tracker:Spawn()
        self.PathTracker = tracker
    end
    ent:SetKeyValue("OnPass", "lambda_path_tracker,OnPass,,0,-1")
end

function GM:ProcessAntlionCollision(ent)
    -- Disable annoying collisions with antlions if allied.
    if (game.GetGlobalState("antlion_allied") == GLOBAL_ON and
        self:GetSetting("friendly_antlion_collision", true) == false) then
        ent:SetCollisionGroup(COLLISION_GROUP_WEAPON)
    end
end

local ENTITY_PROCESSORS =
{
    ["env_hudhint"] = { PostFrame = true, Fn = GM.ProcessEnvHudHint },
    ["env_message"] = { PostFrame = true, Fn = GM.ProcessEnvMessage },
    ["func_areaportal"] = { PostFrame = true, Fn = GM.ProcessFuncAreaPortal },
    ["func_areaportalwindow"] = { PostFrame = true, Fn = GM.ProcessFuncAreaPortalWindow },
    ["logic_choreographed_scene"] = { PostFrame = true, Fn = GM.ProcessLogicChoreographedScene },
    ["path_track"] = { PostFrame = true, Fn = GM.ProcessPathTrackHack },
    ["npc_antlion"] = { PostFrame = true, Fn = GM.ProcessAntlionCollision },
}

function GM:OnEntityCreated(ent)

    if SERVER then
        local class = ent:GetClass()
        local entityProcessor = ENTITY_PROCESSORS[class]

        if entityProcessor ~= nil and entityProcessor.PostFrame == false then
            entityProcessor.Fn(self, ent)
        end

        -- Used to track the entity in case we respawn it.
        ent.UniqueEntityId = ent.UniqueEntityId or self:GetNextUniqueEntityId()

        -- Run this next frame so we can safely remove entities and have their actual names assigned.
        util.RunNextFrame(function()

            if not IsValid(ent) then
                return
            end

            -- Required information for respawning some things.
            ent.InitialSpawnData =
            {
                Pos = ent:GetPos(),
                Ang = ent:GetAngles(),
                Mins = ent:OBBMins(),
                Maxs = ent:OBBMaxs(),
            }

            if ent:IsWeapon() == true then
                self:TrackWeapon(ent)
                if ent:CreatedByMap() == true then
                    DbgPrint("Level designer created weapon: " .. tostring(ent))
                    self:InsertLevelDesignerPlacedObject(ent)
                end
            elseif ent:IsItem() == true then
                if ent:CreatedByMap() == true then
                    DbgPrint("Level designer created item: " .. tostring(ent))
                    self:InsertLevelDesignerPlacedObject(ent)
                end
            end

            if entityProcessor ~= nil and entityProcessor.PostFrame == true then
                entityProcessor.Fn(self, ent)
            end

        end)

        if ent:IsNPC() then
            self:RegisterNPC(ent)
        end

        -- Deal with vehicles at the same frame, sometimes it wouldn't show the gun.
        if ent:IsVehicle() then
            self:HandleVehicleCreation(ent)
        end
    end

end

local function ReplaceFuncTankVolume(ent, volname)

    local newName = "Lambda" .. volname

    ents.WaitForEntityByName(volname, function(vol)

        DbgPrint("Replacing control volume for: " .. tostring(ent), volname)

        local newVol = ents.Create("trigger") -- Yes this actually exists and it has what func_tank needs.
        newVol:SetKeyValue("StartDisabled", "0")
        newVol:SetKeyValue("spawnflags", vol:GetSpawnFlags())
        newVol:SetModel(vol:GetModel())
        newVol:SetMoveType(vol:GetMoveType())
        newVol:SetPos(vol:GetPos())
        newVol:SetAngles(vol:GetAngles())
        newVol:SetName(newName)
        newVol:Spawn()
        newVol:Activate()
        newVol:AddSolidFlags(FSOLID_TRIGGER)
        newVol:SetNotSolid(true)
        newVol:AddEffects(EF_NODRAW)

        -- The previous volume is no longer needed.
        vol:Remove()

    end)

    return newName

end

function GM:EntityKeyValue(ent, key, val)

    if self.MapScript then
        -- Monitor scripts that we have filtered by class name.
        if key:iequals("classname") == true then
            if self.MapScript.EntityFilterByClass and self.MapScript.EntityFilterByClass[val] == true then
                DbgPrint("Removing filtered entity by class: " .. tostring(ent))
                ent:Remove()
                return
            end
        elseif key:iequals("targetname") == true then
            -- Monitor scripts that have filtered by name.
            if self.MapScript.EntityFilterByName and self.MapScript.EntityFilterByName[val] == true then
                DbgPrint("Removing filtered entity by name: " .. tostring(ent) .. " (" .. val .. ")")
                ent:Remove()
                return
            end
        end
    end

    ent.LambdaKeyValues = ent.LambdaKeyValues or {}

    local entClass = ent:GetClass()
    if entClass == "env_sprite" and key == "GlowProxySize" and tonumber(val) > 64 then
        -- Fix console spam about maximum glow size, maximum value is 64.
        return 64
    end
    if key == "globalstate" and val == "friendly_encounter" and entClass == "env_global" then
        -- HACKHACK: This solves an issue that causes prediction errors because clients arent aware of global states.
        return ""
    elseif key == "control_volume" and (entClass == "func_tank" or entClass == "func_tankairboatgun") then
        -- HACKHACK: Because we replace the triggers with lua triggers func_tank will not work with control_volume.
        --           We replace the volume with a new created trigger that is not from lua.
        local newTriggerName = ReplaceFuncTankVolume(ent, val)
        return newTriggerName
    end

    if util.IsOutputValue(key) then
        ent.EntityOutputs = ent.EntityOutputs or {}
        ent.EntityOutputs[key] = ent.EntityOutputs[key] or {}
        table.insert(ent.EntityOutputs[key], val)
    else
        ent.LambdaKeyValues[key] = val
    end

    if self.MapScript.EntityKeyValue then
        res = self.MapScript:EntityKeyValue(ent, key, val)
        if res ~= nil then
            return res
        end
    end

end

function GM:ApplyCorrectedDamage(dmginfo)
 
    DbgPrint("ApplyCorrectedDamage")

    local attacker = dmginfo:GetAttacker()

    if IsValid(attacker) and (dmginfo:IsDamageType(DMG_BULLET) or dmginfo:IsDamageType(DMG_CLUB)) then

        local weaponTable = nil
        local wep = nil

        if attacker:IsPlayer() then
            weaponTable = self.PLAYER_WEAPON_DAMAGE
            wep = attacker:GetActiveWeapon()
        elseif attacker:IsNPC() then
            weaponTable = self.NPC_WEAPON_DAMAGE
            wep = attacker:GetActiveWeapon()
        end

        if weaponTable ~= nil and IsValid(wep) then
            local class = wep:GetClass()
            local dmgCVar = weaponTable[class]
            if dmgCVar ~= nil then
                local dmgAmount = dmgCVar:GetInt()
                DbgPrint("Setting modified weapon damage " .. tostring(dmgAmount) .. " on " .. class)
                dmginfo:SetDamage(dmgAmount)
            end
        end

    end

    return dmginfo

end