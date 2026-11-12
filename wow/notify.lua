local _, ns = ...

-- Gets the player's attention for something that needs an answer soon: a
-- sound, and the WoW icon flashing in the taskbar when the game is in the
-- background.
local Notify = {}

function Notify.attention()
    if PlaySound and not ns.db.noSound then
        pcall(PlaySound, SOUNDKIT and SOUNDKIT.READY_CHECK or 8960)
    end
    if FlashClientIcon and not ns.db.noFlash then
        pcall(FlashClientIcon)
    end
end

ns.Notify = Notify
