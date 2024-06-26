---@class PlayerVehicle
---@field id number
---@field citizenid? string
---@field modelName string
---@field garage string
---@field state VehicleState
---@field depotPrice integer
---@field props table ox_lib properties table

Config = require 'config.server'
SharedConfig = require 'config.shared'
VEHICLES = exports.qbx_core:GetVehiclesByName()
Storage = require 'server.storage'

function FindPlateOnServer(plate)
    local vehicles = GetAllVehicles()
    for i = 1, #vehicles do
        if plate == GetVehicleNumberPlateText(vehicles[i]) then
            return true
        end
    end
end

---@param garage string
---@return GarageType
function GetGarageType(garage)
    if SharedConfig.garages[garage] then
        return SharedConfig.garages[garage].type
    else
        return GarageType.HOUSE
    end
end

---@param source number
---@param garageName string
---@return PlayerVehicle[]?
lib.callback.register('qbx_garages:server:getGarageVehicles', function(source, garageName)
    local garageType = GetGarageType(garageName)
    local player = exports.qbx_core:GetPlayer(source)
    if garageType == GarageType.PUBLIC then -- Public garages give player cars in the garage only
        local playerVehicles = exports.qbx_vehicles:GetPlayerVehicles({
            garage = garageName,
            citizenid = player.PlayerData.citizenid,
            states = VehicleState.GARAGED,
        })
        return playerVehicles[1] and playerVehicles
    elseif garageType == GarageType.DEPOT then -- Depot give player cars that are not in garage only
        local playerVehicles = exports.qbx_vehicles:GetPlayerVehicles({
            citizenid = player.PlayerData.citizenid,
            states = VehicleState.OUT,
        })
        local toSend = {}
        if not playerVehicles[1] then return end
        for _, vehicle in pairs(playerVehicles) do -- Check vehicle type against depot type
            if not FindPlateOnServer(vehicle.props.plate) then
                local vehicleType = SharedConfig.garages[garageName].vehicleType
                if (vehicleType == VehicleType.AIR and (VEHICLES[vehicle.modelName].category == 'helicopters' or VEHICLES[vehicle.modelName].category == 'planes')) or
                   (vehicleType == VehicleType.SEA and VEHICLES[vehicle.modelName].category == 'boats') or
                   (vehicleType == VehicleType.CAR and VEHICLES[vehicle.modelName].category ~= 'helicopters' and VEHICLES[vehicle.modelName].category ~= 'planes' and VEHICLES[vehicle.modelName].category ~= 'boats') then
                    toSend[#toSend + 1] = vehicle
                end
            end
        end
        return toSend
    elseif garageType == GarageType.HOUSE or not Config.sharedGarages then -- House/Personal Job/Gang garages give all cars in the garage
        local playerVehicles = exports.qbx_vehicles:GetPlayerVehicles({
            garage = garageName,
            citizenid = player.PlayerData.citizenid,
            states = VehicleState.GARAGED,
        })
        return playerVehicles[1] and playerVehicles
    else -- Job/Gang shared garages
        local playerVehicles = exports.qbx_vehicles:GetPlayerVehicles({
            garage = garageName,
            states = VehicleState.GARAGED,
        })
        return playerVehicles[1] and playerVehicles
    end
end)

---@param source number
---@param vehicleId string
---@param garageName string
---@return boolean
local function isParkable(source, vehicleId, garageName)
    local garageType = GetGarageType(garageName)
    assert(vehicleId ~= nil, 'owned vehicles must have vehicle ids')
    local player = exports.qbx_core:GetPlayer(source)
    local garage = SharedConfig.garages[garageName]
    if garageType == GarageType.PUBLIC then -- All players can park in public garages
        return true
    elseif garageType == GarageType.HOUSE then -- House garages only for player cars that have keys of the house
        local playerVehicle = exports.qbx_vehicles:GetPlayerVehicle(vehicleId)
        return Config.hasHouseGarageKey(garageName, playerVehicle.citizenid)
    elseif garageType == GarageType.JOB then
        if player.PlayerData.job?.name ~= garage.group then return false end
        if Config.sharedGarages then
            return true
        else
            local playerVehicle = exports.qbx_vehicles:GetPlayerVehicle(vehicleId)
            return playerVehicle.citizenid == player.PlayerData.citizenid
        end
    elseif garageType == GarageType.GANG then
        if player.PlayerData.gang?.name ~= garage.group then return false end
        if Config.sharedGarages then
            return true
        else
            local playerVehicle = exports.qbx_vehicles:GetPlayerVehicle(vehicleId)
            return playerVehicle.citizenid == player.PlayerData.citizenid
        end
    end
    error("Unhandled GarageType: " .. garageType)
end

lib.callback.register('qbx_garages:server:isParkable', function(source, garage, netId)
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    local vehicleId = Entity(vehicle).state.vehicleid
    return isParkable(source, vehicleId, garage)
end)

---@param source number
---@param netId number
---@param props table ox_lib vehicle props https://github.com/overextended/ox_lib/blob/master/resource/vehicleProperties/client.lua#L3
---@param garage string
lib.callback.register('qbx_garages:server:parkVehicle', function(source, netId, props, garage)
    local garageType = GetGarageType(garage)
    assert(garageType == GarageType.HOUSE or SharedConfig.garages[garage] ~= nil, string.format('Garage %s not found in config', garage))
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    local owned = isParkable(source, Entity(vehicle).state.vehicleid, garage) --Check ownership
    if not owned then
        exports.qbx_core:Notify(source, Lang:t('error.not_owned'), 'error')
        return
    end

    local vehicleId = Entity(vehicle).state.vehicleid
    Storage.saveVehicle(vehicleId, props, garage)
    DeleteEntity(vehicle)
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= cache.resource then return end
    Wait(100)
    if Config.autoRespawn then
        Storage.moveOutVehiclesIntoGarages()
    end
end)

---@param vehicleId string
---@return boolean? success true if successfully paid
lib.callback.register('qbx_garages:server:payDepotPrice', function(source, vehicleId)
    local player = exports.qbx_core:GetPlayer(source)
    local cashBalance = player.PlayerData.money.cash
    local bankBalance = player.PlayerData.money.bank

    local vehicle = exports.qbx_vehicles:GetPlayerVehicle(vehicleId)
    local depotPrice = vehicle.depotPrice
    if not depotPrice or depotPrice == 0 then return true end
    if cashBalance >= depotPrice then
        player.Functions.RemoveMoney('cash', depotPrice, 'paid-depot')
        return true
    elseif bankBalance >= depotPrice then
        player.Functions.RemoveMoney('bank', depotPrice, 'paid-depot')
        return true
    end
end)
