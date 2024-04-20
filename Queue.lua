--[[
    QueueEntry:
    {
        playerId: string | number, // Confuso.
        priority: number,

        updateDeferrals: (messsage) => void,
        setDeferralsDone: (errMsg) => void,

        enteredAt: Date;

        lastIndex: number;
        secondsOnQueue: number;

        isNoLongerNeeded: boolean;

        isJoining: boolean; // Quando o player está se conectando realmente na sessão do servidor.
    }
]]

local USE_DEBUG = false

local SV_MAX_CLIENTS = GetConvarInt('sv_maxClients', 32)

local USE_PRIORITY = true

local MIN_TIME_ON_QUEUE_BEFORE_CONNECTION = 7

local THROTTLING_THRESHOLD_PERCENTAGE = 10

local gEntries = { }
local gEntryByPlayerId = { }

local gCachedNumConnectedPlayers = GetNumPlayerIndices()

local gIsThrollingEnabled = false

local gPlayerTempIdThrottlingConnection = nil
local gPlayerIdThrottlingConnection = nil

function Init()
    AddEventHandler('playerConnectionAuthenticated', HandlePlayerConnectionAuthenticated)
    AddEventHandler('playerConnectionBailed'  , HandlePlayerConnectionBailed  )
    AddEventHandler('playerConnected'         , HandlePlayerConnected         )

    while true do
        OnTick()
    end
end

CreateThread(function()
    Init()
end)

function HandlePlayerConnectionAuthenticated(playerId, updateDeferrals, setDeferralsDone, priority)
    --[[ Cancelar o evento já que a gente vai dizer quando o player deve conectar ou não ]]
    CancelEvent()

    if gEntryByPlayerId[playerId] then
        RemovePlayerEntry(playerId)
    end

    local entry =
    {
        playerId = playerId,
        priority = USE_PRIORITY and priority or 0,

        updateDeferrals = updateDeferrals,
        setDeferralsDone = setDeferralsDone,

        enteredAt = GetGameTimer(),

        --[[ Cache do ultimo index(ordem) para não precisar atualizar o deferrals caso não seja alterado. ]]
        lastIndex = nil,
        secondsOnQueue = nil,
    }

    table.insert(gEntries, entry)
    gEntryByPlayerId[playerId] = entry
end

--[[
    Quando o player recusa/cancela a conexão em meio à fila.
    talvez não seja realmente usado e o `dispose` seja usado no lugar.

    Bem provavel que isso daqui seja inutil, mas fazer o que :)
]]
function HandlePlayerConnectionBailed(playerId)
    if USE_DEBUG then
        print('HandlePlayerConnectionBailed', playerId, type(playerId), playerId ~= nil and GetPlayerName(playerId) or 'nil', gPlayerIdThrottlingConnection, type(gPlayerIdThrottlingConnection))
    end

    MarkEntryAsNoLongerNeededByPlayerId(playerId)

    if gPlayerIdThrottlingConnection == playerId then
        gPlayerIdThrottlingConnection = nil
        gPlayerTempIdThrottlingConnection = nil
    end
end

function HandlePlayerConnected(playerId)
    RemovePlayerEntry(playerId)
end

function OnTick()
    Wait(500)

    local keptEntries = { }
    local numKeptEntries = 0

    --[[
        Vai organizar a lista em ordem decrescente
        1, 2, 5, 5, 10, 99, ...
    ]]
    if USE_PRIORITY then
        table.sort(gEntries, function(A, B)
            return (A.priority > B.priority)
        end)
    end

    local numEntries <const> = #gEntries

    local numDisposedEntries = 0

    local numConnectedPlayers <const> = GetNumPlayerIndices()

    local hasNumConnectedPlayersChanged <const> = gCachedNumConnectedPlayers ~= numConnectedPlayers
    if hasNumConnectedPlayersChanged then
        gCachedNumConnectedPlayers = numConnectedPlayers
    end

    gIsThrollingEnabled = numConnectedPlayers >= (SV_MAX_CLIENTS - (SV_MAX_CLIENTS * (THROTTLING_THRESHOLD_PERCENTAGE / 100  )))

    local isThereAThrollingPlayer = gPlayerIdThrottlingConnection ~= nil

    local now <const> = GetGameTimer()

    for realIndex = 1, numEntries do
        local entry = gEntries[realIndex]

        local index = isThereAThrollingPlayer and (realIndex - 1) or realIndex

        local playerId, updateDeferrals, setDeferralsDone, enteredAt in entry

        local function keep()
            numKeptEntries += 1

            keptEntries[numKeptEntries] = entry
        end

        local function dispose()
            numDisposedEntries += 1

            if USE_DEBUG then
                print('Disposing of entry', entry) 
            end
        end

        local secondsOnQueue = math.floor((now - enteredAt) / 1000)
        -- local secondsToRefuse = MIN_TIME_ON_QUEUE_BEFORE_CONNECTION - secondsOnQueue

        local hasIndexChanged          = index ~= entry.lastIndex
        local hasSecondsOnQueueChanged = secondsOnQueue ~= entry.secondsOnQueue

        local shouldUpdateDeferrals = hasNumConnectedPlayersChanged
                                    or hasIndexChanged
                                    or hasSecondsOnQueueChanged

        if shouldUpdateDeferrals then

            --[[ ClockTime provavelmente vai dar overflow caso passe de 24 horas. ]]
            local clockTime = os.date('!%X', secondsOnQueue)

            updateDeferrals( (i18n.translate("queue_position")):format( index, numEntries, clockTime, isThereAThrollingPlayer and ' Throttled' or '') )

            if hasIndexChanged then
                entry.lastIndex = index
            end

            if hasSecondsOnQueueChanged then
                entry.secondsOnQueue = secondsOnQueue
            end
        end
        
        -- #TODO: Criar um Adapative Card.

        if entry.isNoLongerNeeded then

            if USE_DEBUG then
                print('Entry disposed as no longer needed')
            end

            dispose()

            --[[ Ignorar todas outras condições já que o player não é mais importante para o Queue. ]]
            goto continue
        end

        if secondsOnQueue >= MIN_TIME_ON_QUEUE_BEFORE_CONNECTION
        and index == 1
        and numConnectedPlayers < SV_MAX_CLIENTS then
            setDeferralsDone()

            entry.isJoining = true

            if gIsThrollingEnabled then
                gPlayerIdThrottlingConnection = playerId
            else
                MarkEntryAsNoLongerNeededByPlayerId(playerId)
            end

            if USE_DEBUG then
                print( (i18n.translate("player_connecting")):format(playerId, GetPlayerName(playerId)) )
            end
        else
            keep()
        end

        --[[ Existe um player se conectando, porém ele se desconectou, então a gente a vai remover ele no proximo tick com o `MarkEntryAsNoLongerNeededByPlayerId` ]]
        if isThereAThrollingPlayer and (gPlayerIdThrottlingConnection and GetPlayerEndpoint(gPlayerIdThrottlingConnection)) == nil then
            gPlayerIdThrottlingConnection = nil
            gPlayerTempIdThrottlingConnection = nil

            MarkEntryAsNoLongerNeededByPlayerId(playerId)

            if USE_DEBUG then
                print('Um Queue entry se desconectou enquando estava carregando para dentro do jogo, marked as no longer needed.')
            end
        end

        if GetPlayerEndpoint(playerId) == nil --[[ and not entry.isJoining ]] --[[ Só executar o bailed caso o player ainda esteja na parte do deferrals ]] then
            TriggerEvent('playerConnectionBailed', playerId, i18n.translate('diconnected_from_queue'))
            
            if USE_DEBUG then
                print('Queue entry markes as no longer needed because the players endpoint is nill')
            end
        end

        ::continue::
    end

    if numDisposedEntries > 0 then
        table.wipe(gEntries)

        gEntries = keptEntries
    end
end

function FindEntry(playerId)
    for index, itEntry in ipairs(gEntries) do
        if itEntry.playerId == playerId then
            return itEntry
        end
    end

    return nil
end

function FindEntryIndex(entry)
    for index, itEntry in ipairs(gEntries) do
        if itEntry == entry then
            return index
        end
    end

    return -1
end

function RemoveEntry(entry)
    local index = FindEntryIndex(entry)

    if index == -1 then
        return
    end

    table.remove(gEntries, index)
end

function RemovePlayerEntry(playerId)
    local entry = gEntryByPlayerId[playerId]

    if not entry then
        return
    end

    RemoveEntry(entry)
end

AddEventHandler('playerJoining', function(tempNetId)
    local playerId = source

    if USE_DEBUG then
        print('playerJoining', tempNetId, playerId, GetPlayerName(playerId), gPlayerIdThrottlingConnection, type(tempNetId), type(gPlayerIdThrottlingConnection))
    end

    --[[ gPlayerIdThrottlingConnection é uma string ]]
    if tonumber(tempNetId) == gPlayerIdThrottlingConnection then
        gPlayerTempIdThrottlingConnection = gPlayerIdThrottlingConnection
        gPlayerIdThrottlingConnection = playerId
    end
end)

RegisterNetEvent('queue:playerFullyConnected', function()
    local playerId = source

    if USE_DEBUG then
        print('queue:playerFullyConnected', playerId, type(playerId), GetPlayerName(playerId), gPlayerIdThrottlingConnection, type(gPlayerIdThrottlingConnection))
    end

    --[[ gPlayerIdThrottlingConnection é number, playerId é number. ]]
    --[[ O player realmente entrou no jogo, se livrar da instancia dele no queue. ]]
    if gPlayerIdThrottlingConnection == tonumber(playerId) then
        MarkEntryAsNoLongerNeededByPlayerId(gPlayerTempIdThrottlingConnection)

        gPlayerIdThrottlingConnection = nil
        gPlayerTempIdThrottlingConnection = nil
    end
end)

function MarkEntryAsNoLongerNeededByPlayerId(playerId)
    local entry = FindEntry(playerId)

    if entry then
        entry.isNoLongerNeeded = true
    end
end