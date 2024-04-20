Citizen.CreateThread(function()
	while true do
		Wait(0)

		if NetworkIsSessionStarted() then
			TriggerServerEvent('queue:playerFullyConnected')
			return
		end
	end
end)