-- Player-side view of the last complete authority snapshot.
local Menu = {}

function Menu.draw(player, ui)
  if ui.Begin("Hades2Together | My rewards") then
    ui.TextUnformatted(player.seat and ("Seat " .. player.seat) or player.connection)
    local room = player.snapshot and player.snapshot.room
    local hasClaim = false
    for _, reward in ipairs(room and room.rewards or {}) do
      for _, claim in ipairs(reward.claims or {}) do
        if claim.playerId == player.seat then
          hasClaim = true
          ui.TextUnformatted(reward.kind .. " #" .. reward.id .. " | " .. claim.state)
          if claim.choice then ui.TextUnformatted(claim.choice) end
          if claim.opportunity and not room.leaving then
            for _, option in ipairs(claim.grantOptions or { claim.grantOption }) do
              if ui.Button(option .. "##" .. claim.opportunity) then
                local sent, reason = player:chooseBoon(claim.opportunity, option)
                player.boonFeedback = { opportunity = claim.opportunity,
                  text = sent and ("Sent: " .. option) or tostring(reason) }
              end
            end
            local feedback = player.boonFeedback
            if feedback and feedback.opportunity == claim.opportunity then ui.TextUnformatted(feedback.text) end
          end
        end
      end
    end
    if not hasClaim then ui.TextUnformatted("No reward for this seat in the current snapshot.") end
    if player.reason then ui.TextUnformatted("Last message: " .. player.reason) end
  end
  ui.End()
end

return Menu
