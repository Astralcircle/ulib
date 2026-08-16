--[[
	Title: Bans

	Ban-related functions and listeners.
]]

-- ULib default ban message
ULib.BanMessage = [[
-------===== [ BANNED ] =====-------

---= Reason =---
{{REASON}}

---= Time Left =---
{{TIME_LEFT}} ]]

function ULib.getBanMessage( steamid, banData, templateMessage )
	banData = banData or ULib.getBan( steamid )
	if not banData then return end
	templateMessage = templateMessage or ULib.BanMessage

	local replacements = {
		BANNED_BY = "(Unknown)",
		BAN_START = "(Unknown)",
		REASON = "(None given)",
		TIME_LEFT = "(Permaban)",
		STEAMID = steamid,
		STEAMID64 = util.SteamIDTo64( steamid ),
	}

	if banData.admin and banData.admin ~= "" then
		replacements.BANNED_BY = banData.admin
	end

	local time = tonumber( banData.time )
	if time and time > 0 then
		replacements.BAN_START = os.date( "%c", time )
	end

	if banData.reason and banData.reason ~= "" then
		replacements.REASON = banData.reason
	end

	local unban = tonumber( banData.unban )
	if unban and unban > 0 then
		replacements.TIME_LEFT = ULib.secondsToStringTime( unban - os.time() )
	end

  	local banMessage = templateMessage:gsub( "{{([%w_]+)}}", replacements )
	return banMessage
end

local function checkBan( steamid64, ip, password, clpassword, name )
	local steamid = util.SteamIDFrom64( steamid64 )
	local banData = ULib.getBan( steamid )
	if not banData then return end -- Not banned

	-- Nothing useful to show them, go to default message
	if not banData.admin and not banData.reason and not banData.unban and not banData.time then return end

	local message = ULib.getBanMessage( steamid )
	Msg(string.format("%s (%s)<%s> was kicked by ULib because they are on the ban list\n", name, steamid, ip))
	return false, message
end
hook.Add( "CheckPassword", "ULibBanCheck", checkBan, HOOK_HIGH )

--[[
	Function: ban

	Bans a user.

	Parameters:

		ply - The player to ban.
		time - *(Optional)* The time in minutes to ban the person for, leave nil or 0 for permaban.
		reason - *(Optional)* The reason for banning
		admin - *(Optional)* Admin player enacting ban

	Revisions:

		v2.10 - Added support for custom ban list
]]
function ULib.ban( ply, time, reason, admin )
	if not time or type( time ) ~= "number" then
		time = 0
	end

	if ply:IsListenServerHost() then
		return
	end

	ULib.addBan( ply:SteamID(), time, reason, ply:Name(), admin )
end


--[[
	Function: kickban

	An alias for <ban>.
]]
ULib.kickban = ULib.ban

local function writeBan( bandata )
	sql.QueryTyped( "REPLACE INTO ulib_bans (steamid, time, unban, reason, name, admin, modified_admin, modified_time) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
		util.SteamIDTo64( bandata.steamID ),
		bandata.time or 0,
		bandata.unban or 0,
		bandata.reason,
		bandata.name,
		bandata.admin,
		bandata.modified_admin,
		bandata.modified_time
	)
end


--[[
	Function: addBan

	Helper function to store additional data about bans.

	Parameters:

		steamid - Banned player's steamid
		time - Length of ban in minutes, use 0 for permanant bans
		reason - *(Optional)* Reason for banning
		name - *(Optional)* Name of player banned
		admin - *(Optional)* Admin player enacting the ban

	Revisions:

		2.10 - Initial
		2.40 - If the steamid is connected, kicks them with the reason given
]]
function ULib.addBan( steamid, time, reason, name, admin )
	if reason == "" then reason = nil end

	local admin_name
	if admin then
		if isstring(admin) then
			admin_name = admin
		elseif not IsValid(admin) then
			admin_name = "(Console)"
		elseif admin:IsPlayer() then
			admin_name = string.format("%s(%s)", admin:Name(), admin:SteamID())
		end
	end

	-- Clean up passed data
	local t = {}
	local timeNow = os.time()
	local banData = ULib.getBan( steamid )
	if banData then
		t = banData
		t.modified_admin = admin_name
		t.modified_time = timeNow
	else
		t.admin = admin_name
	end
	t.time = t.time or timeNow
	if time > 0 then
		t.unban = ( ( time * 60 ) + timeNow )
	else
		t.unban = 0
	end
	t.reason = reason
	t.name = name
	t.steamID = steamid

	local strTime = time ~= 0 and ULib.secondsToStringTime( time*60 )
	local shortReason = "Banned for " .. (strTime or "eternity")
	if reason then
		shortReason = shortReason .. ": " .. reason
	end

	local longReason = shortReason
	if reason or strTime or admin then -- If we have something useful to show
		longReason = "\n" .. ULib.getBanMessage( steamid ) .. "\n" -- Newlines because we are forced to show "Disconnect: <msg>."
	end

	local ply = player.GetBySteamID( steamid )
	if ply then
		ULib.kick( ply, longReason, nil, true)
	end

	-- This redundant kick is to ensure they're kicked -- even if they're joining
	game.KickID( steamid, shortReason or "" )

	writeBan( t )
	hook.Call( ULib.HOOK_USER_BANNED, _, steamid, t )
end


--[[
	Function: unban

	Unbans the given steamid.

	Parameters:

		steamid - The steamid to unban.
		admin - *(Optional)* Admin player unbanning steamid

	Revisions:

		v2.10 - Initial
]]
function ULib.unban( steamid, admin )
	--ULib banlist
	sql.QueryTyped( "DELETE FROM ulib_bans WHERE steamid = ?", util.SteamIDTo64( steamid ) )
	hook.Call( ULib.HOOK_USER_UNBANNED, _, steamid, admin )

end

-- Init our bans table
if not sql.TableExists( "ulib_bans" ) then
	sql.QueryTyped( "CREATE TABLE IF NOT EXISTS ulib_bans ( " ..
		"steamid INTEGER NOT NULL PRIMARY KEY, " ..
		"time INTEGER NOT NULL, " ..
		"unban INTEGER NOT NULL, " ..
		"reason TEXT, " ..
		"name TEXT, " ..
		"admin TEXT, " ..
		"modified_admin TEXT, " ..
		"modified_time INTEGER " ..
		")"
	)

	sql.QueryTyped( "CREATE INDEX IDX_ULIB_BANS_TIME ON ulib_bans ( time DESC )" )
	sql.QueryTyped( "CREATE INDEX IDX_ULIB_BANS_UNBAN ON ulib_bans ( unban DESC )" )
end

--[[
	Function: getBan

	Returns whether a player is banned
]]
function ULib.isBanned( steamid )
	return sql.QueryTyped( "SELECT 1 FROM ulib_bans WHERE steamid = ? LIMIT 1", util.SteamIDTo64( steamid ) )[1] ~= nil
end


--[[
	Function: getBan

	Returns info about specific player ban
]]
function ULib.getBan( steamid )
	local ban = sql.QueryTyped( "SELECT * FROM ulib_bans WHERE steamid = ?", util.SteamIDTo64( steamid ) )[1]

	-- Backwards compatibility
	if ban then
		ban.steamID = util.SteamIDFrom64( ban.steamid )
		ban.steamid = nil
		return ban
	end
end

--[[
	Function: getBans

	Returns internal table of all bans
]]
function ULib.getBans()
	return sql.QueryTyped( "SELECT * FROM ulib_bans" )
end
