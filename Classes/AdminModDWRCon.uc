/**
 * AdminModDW remote console. Extends AOCRCon with ChivAdmin's command set plus our own.
 *
 * This is the Deadliest Warrior port of AdminMod. AOCRCon.uc is byte-identical between the
 * two SDKs and AOCRConPacket differs only in parameter names, so the wire format, the
 * opcode numbers and the payload layouts are the SAME -- one ChivRcon client talks to both.
 * Where Deadliest Warrior's game code differs, the handler is reimplemented against it
 * rather than the opcode being moved or dropped. Those deltas are listed in
 * RCON_PROTOCOL.md under "Deadliest Warrior".
 *
 * 0-22 are vanilla, in AOCRCon's MessageType order. 23-28 exist only in the ChivAdmin
 * client (its mutator was never published); implementing them means an unmodified
 * ChivAdmin client works here. 29+ are ours -- unknown opcodes are ignored, so adding
 * them cannot break that client. Full table and payloads: RCON_PROTOCOL.md.
 *
 * Every state-changing command calls AdminModDWAudit: logged, and echoed as
 * RCONX_ADMIN_AUDIT. RCON is password-authenticated but otherwise unrestricted, and
 * opcode 28 is arbitrary execution, so that power should be visible rather than quiet.
 */
class AdminModDWRCon extends AOCRCon;

// ---- ChivAdmin mutator parity ------------------------------------------------
const RCONX_PING_EXTENDED        = 23;
const RCONX_CHANGE_SCORE         = 24;
const RCONX_KILL_PLAYER          = 25;
const RCONX_INEBRIATE            = 26;
const RCONX_CHANGE_GAME_PASSWORD = 27;
const RCONX_CONSOLE_COMMAND      = 28;

// ---- AdminMod additions -------------------------------------------------------
const RCONX_PLAYER_LIST_REQUEST  = 29;  // in : (no body)
const RCONX_PLAYER_INFO          = 30;  // out: one per player, see SendPlayerInfo
const RCONX_PLAYER_LIST_END      = 31;  // out: marks the end of a list burst
const RCONX_SET_TEAM             = 32;  // in : QWord uid, int team
const RCONX_FORCE_SPECTATE       = 33;  // in : QWord uid
const RCONX_SET_TEAM_SCORE       = 34;  // in : int team, int score
const RCONX_ADMIN_AUDIT          = 35;  // out: string action, string detail
const RCONX_SERVER_INFO_REQUEST  = 36;  // in : (no body)
const RCONX_SERVER_INFO          = 37;  // out: see SendServerInfo
const RCONX_CONSOLE_RESULT       = 38;  // out: string command, string result
const RCONX_BAN_LIST_REQUEST     = 39;  // in : (no body)
const RCONX_BAN_INFO             = 40;  // out: one per ban, see SendBanInfo
const RCONX_BAN_LIST_END         = 41;  // out: int count
const RCONX_MUTE_PLAYER          = 42;  // in : QWord uid, int mute
const RCONX_SET_PAUSE            = 43;  // in : int paused
const RCONX_END_MATCH            = 44;  // in : int winningTeam, string reason
const RCONX_SET_AUTOBALANCE      = 45;  // in : int enabled
const RCONX_SET_GAME_SPEED       = 46;  // in : int speedPercent (100 = normal)
const RCONX_RESTART_MATCH        = 47;  // in : (no body)
const RCONX_SOBER_PLAYER         = 48;  // in : QWord uid
const RCONX_SET_TOURNAMENT       = 49;  // in : int enabled, int thresholdPercent (0 = leave)
const RCONX_READY_ALL            = 50;  // in : int ready (1 = ready all, 0 = clear all)
const RCONX_SET_FROZEN           = 51;  // in : QWord uid, int frozen
const RCONX_SET_CLASS            = 52;  // in : QWord uid, int classIndex, int immediate
const RCONX_LOADOUT_REQUEST      = 53;  // in : QWord uid
const RCONX_LOADOUT_OPTION       = 54;  // out: QWord uid, int slot, int index, string weapon
const RCONX_LOADOUT_END          = 55;  // out: QWord uid, int prim, int sec, int tert
const RCONX_SET_LOADOUT          = 56;  // in : QWord uid, int prim, int sec, int tert (-1 = leave)
const RCONX_PLAYER_POS_REQUEST   = 57;  // in : (no body)
const RCONX_PLAYER_POS           = 58;  // out: see SendPlayerPositions
const RCONX_PLAYER_POS_END       = 59;  // out: int count
const RCONX_TELEPORT             = 60;  // in : QWord who, QWord toWhom
const RCONX_SLAP                 = 61;  // in : QWord uid, int power
const RCONX_MUTE_LIST_REQUEST    = 62;  // in : (no body)
const RCONX_MUTE_INFO            = 63;  // out: one per muted player, QWord uid, string name, int team
const RCONX_MUTE_LIST_END        = 64;  // out: int count

const SLOT_PRIMARY   = 0;
const SLOT_SECONDARY = 1;
const SLOT_TERTIARY  = 2;

const SCOPE_GAME        = 0;
const SCOPE_PLAYER      = 1;
const SCOPE_ALL_PLAYERS = 2;

/**
 * Console verbs RCON refuses to run, matched case-insensitively on the first token.
 * Scope 1 runs on the SERVER-side controller, so "quit" on a player kills the server.
 * config(Game) is inherited, so admins can extend this in UDKGame.ini under
 * [AdminModDW.AdminModDWRCon].
 */
var config array<string> AdminModDWBlockedConsoleCommands;

/** Set while opcode 43 has forced GameInfo.bPauseable on, with the value to put back. */
var bool bAdminModDWPauseForced;
var bool bAdminModDWPauseableWas;

/**
 * Tournament mode (opcode 49). Deadliest Warrior has no tournament mode of its own, so the
 * state lives here and AdminModDWGame.uci's ShouldCountDown override reads it. Kept on the
 * RCON actor rather than the gametype because the nine AdminModDW gametypes share no base
 * class, and because this actor already survives seamless travel.
 *
 * Listener-only state: read it through AdminModDWShared().
 */
var bool  bAdminModDWTournamentMode;

/** Fraction of each team that must be ready before the round counts down. 1.0 = everyone. */
var float AdminModDWReadyThreshold;

/** Set by opcode 50 with ready=1; makes ShouldCountDown return true until an admin clears it. */
var bool  bAdminModDWForcedReady;

/**
 * Who has readied up, by Steam ID. Listener-only state -- reach it through
 * AdminModDWShared().
 *
 * This is OUR flag, not AOCPlayerController.bReady, and that is the whole point. In
 * Deadliest Warrior bReady means "has picked a class and is not sitting in a menu":
 * SetReady(true) fires on closing team select or confirming a loadout
 * (AOCGFx_TeamSelection.uc:126, AOCView_Loadout.uc:936) and SetReady(false) fires on
 * OPENING any of those menus (AOCBaseHUD.uc:2022/2038/2058). Vanilla uses it as a join
 * gate and that is all it is. Gating a tournament on it is satisfied the moment everyone
 * spawns, and un-satisfied again the moment somebody opens their loadout.
 *
 * Steam ID rather than a PRI pointer so a reconnect inside the pre-round does not silently
 * keep a stale ready.
 */
var array<UniqueNetId> AdminModDWReadyIds;

/** Throttle for the "still waiting" line; the pre-round asks us every second. */
var float fAdminModDWNextWaitAnnounce;

/** Seconds between "still waiting on N" lines while the round is held. */
const READY_WAIT_ANNOUNCE_INTERVAL = 15.0;

/** Set on a session actor; none on the listener. Distinguishes the two at runtime. */
var AdminModDWRCon ParentLink;

/** Live sessions. Listener only. */
var array<AdminModDWRCon> Sessions;

/**
 * Persistent text mutes, mirroring AOCAccessControl.BanInfo/Bans. globalconfig so the
 * session subclass shares the listener's section ([AdminModDW.AdminModDWRCon] in
 * UDKGame.ini) rather than keeping its own copy, and so a mute survives a restart the way
 * a ban does.
 */
struct MuteInfo
{
	var UniqueNetId NetID;
	var string PlayerName;
	var string NetIDAsString;
};

var globalconfig array<MuteInfo> Mutes;

/** Index into the shared mute list, or INDEX_NONE. */
function int AdminModDWFindMute(UniqueNetId NetID)
{
	local int i;

	for (i = 0; i < AdminModDWShared().Mutes.Length; i++)
	{
		if (AdminModDWShared().Mutes[i].NetID == NetID)
			return i;
	}

	return INDEX_NONE;
}

/**
 * Add or drop a persistent mute and write it straight to the ini.
 *
 * SaveConfig is deliberate: AOCAccessControl.UnbanByUID drops the entry from the array and
 * never saves, so the ban is back on the next restart. Not repeating that here.
 */
function AdminModDWRememberMute(UniqueNetId NetID, string PlayerName, bool bMute)
{
	local AdminModDWRCon Listener;
	local MuteInfo MI;
	local int i;

	Listener = AdminModDWShared();
	i = AdminModDWFindMute(NetID);

	if (bMute)
	{
		if (i != INDEX_NONE)
			return;

		MI.NetID         = NetID;
		MI.PlayerName    = PlayerName;
		MI.NetIDAsString = class'OnlineSubsystem'.static.UniqueNetIdToString(NetID);
		Listener.Mutes[Listener.Mutes.Length] = MI;
	}
	else
	{
		if (i == INDEX_NONE)
			return;

		Listener.Mutes.Remove(i, 1);
	}

	Listener.SaveConfig();
}

/**
 * Re-apply a stored mute as the player joins.
 *
 * AOCGame.PostLogin pushes GameEvent_PlayerConnect at the listener, so gating on
 * ParentLink keeps this off the per-session replay SendCurrentGameInfo does for every
 * already-connected player.
 */
function AdminModDWReapplyMute(PlayerReplicationInfo PRI)
{
	local AOCPRI APRI;

	APRI = AOCPRI(PRI);

	if (ParentLink != none || APRI == none || APRI.bIsAdminMuted)
		return;

	if (AdminModDWFindMute(PRI.UniqueId) == INDEX_NONE)
		return;

	APRI.bIsAdminMuted = true;
	APRI.bForceNetUpdate = true;
	AdminModDWAudit("MUTE_REAPPLIED", APRI.PlayerName);
}

/* ============================ tournament readiness ========================== */

/** Index into the shared ready list, or INDEX_NONE. */
function int AdminModDWFindReady(UniqueNetId NetID)
{
	local int i;

	for (i = 0; i < AdminModDWShared().AdminModDWReadyIds.Length; i++)
	{
		if (AdminModDWShared().AdminModDWReadyIds[i] == NetID)
			return i;
	}

	return INDEX_NONE;
}

/** Asked once per player per second by ShouldCountDown, so it stays cheap. */
function bool AdminModDWIsPlayerReady(PlayerReplicationInfo PRI)
{
	return PRI != none && AdminModDWFindReady(PRI.UniqueId) != INDEX_NONE;
}

/** Returns TRUE if this actually changed anything, so callers can stay quiet otherwise. */
function bool AdminModDWSetPlayerReady(PlayerReplicationInfo PRI, bool bReady)
{
	local int i;

	if (PRI == none)
		return false;

	i = AdminModDWFindReady(PRI.UniqueId);

	if (bReady)
	{
		if (i != INDEX_NONE)
			return false;

		AdminModDWShared().AdminModDWReadyIds[AdminModDWShared().AdminModDWReadyIds.Length] = PRI.UniqueId;
		return true;
	}

	if (i == INDEX_NONE)
		return false;

	AdminModDWShared().AdminModDWReadyIds.Remove(i, 1);
	return true;
}

/** Wipe every ready flag. Called when a round starts and when tournament mode is toggled. */
function AdminModDWClearReady()
{
	AdminModDWShared().AdminModDWReadyIds.Length = 0;
	AdminModDWShared().bAdminModDWForcedReady = false;
	AdminModDWShared().fAdminModDWNextWaitAnnounce = 0.0;
}

/** Ready and total, counting only players a tournament actually waits on. */
function AdminModDWReadyTally(out int NumReady, out int NumTotal)
{
	local AOCPlayerController PC;

	NumReady = 0;
	NumTotal = 0;

	foreach WorldInfo.AllControllers(class'AOCPlayerController', PC)
	{
		if (PC.IsVoluntarySpectator() || PC.PlayerReplicationInfo == none
			|| PC.PlayerReplicationInfo.bOnlySpectator)
			continue;

		NumTotal++;
		if (AdminModDWIsPlayerReady(PC.PlayerReplicationInfo))
			NumReady++;
	}
}

/**
 * Chat is the only channel here: Deadliest Warrior has no ready UI and nothing on its GRI or
 * PRI to replicate a ready flag through, so a scoreboard tick is not available without
 * shipping a HUD.
 */
function AdminModDWAnnounceReady(string Text, string Col)
{
	local AOCGame Game;

	Game = AOCGame(WorldInfo.Game);
	if (Game == none)
		return;

	Game.BroadcastMessage(none, Text, EFAC_ALL, true, true, Col);
}

/** "3/6 ready" -- appended to every readiness line so nobody has to ask. */
function string AdminModDWReadyProgress()
{
	local int NumReady, NumTotal;

	AdminModDWReadyTally(NumReady, NumTotal);
	return "(" $ NumReady $ "/" $ NumTotal $ " ready)";
}

/**
 * The "still waiting" nag, throttled. Called from ShouldCountDown, which the pre-round runs
 * once a second -- without the gate this would be a wall of text.
 */
function AdminModDWAnnounceStillWaiting()
{
	local int NumReady, NumTotal;

	if (WorldInfo.TimeSeconds < AdminModDWShared().fAdminModDWNextWaitAnnounce)
		return;

	AdminModDWShared().fAdminModDWNextWaitAnnounce =
		WorldInfo.TimeSeconds + READY_WAIT_ANNOUNCE_INTERVAL;

	AdminModDWReadyTally(NumReady, NumTotal);

	AdminModDWAnnounceReady("Tournament mode: waiting on" @ (NumTotal - NumReady)
		@ "more player(s). Type !ready when you are set.", "#D1A04A");
}

/**
 * Consume "!ready" / "!unready" from chat. Returns TRUE when the message was a command and
 * must not reach the rest of the server.
 *
 * Handled ahead of the mute check on purpose: readying up is a game action, not talking, so
 * a text-muted player is still allowed to do it.
 */
function bool AdminModDWHandleReadyCommand(AOCPlayerController PC, string Message)
{
	local string Cmd;
	local bool bWantReady;

	if (PC == none || PC.PlayerReplicationInfo == none)
		return false;

	Cmd = Locs(Message);
	while (Left(Cmd, 1) == " ")
		Cmd = Mid(Cmd, 1);
	while (Right(Cmd, 1) == " ")
		Cmd = Left(Cmd, Len(Cmd) - 1);

	if (Cmd == "!ready" || Cmd == "!r")
		bWantReady = true;
	else if (Cmd == "!unready" || Cmd == "!notready")
		bWantReady = false;
	else
		return false;

	// Always consume the command, even with tournament mode off -- echoing "!ready" into
	// everyone's chat as if it were conversation is worse than a one-line explanation.
	if (!AdminModDWShared().bAdminModDWTournamentMode)
	{
		PC.ReceiveChatMessage("", "Tournament mode is not on.", EFAC_ALL, true, true, "#D1A04A");
		return true;
	}

	if (PC.IsVoluntarySpectator() || PC.PlayerReplicationInfo.bOnlySpectator)
	{
		PC.ReceiveChatMessage("", "Spectators are not counted.", EFAC_ALL, true, true, "#D1A04A");
		return true;
	}

	if (!AdminModDWSetPlayerReady(PC.PlayerReplicationInfo, bWantReady))
	{
		PC.ReceiveChatMessage("", bWantReady ? "You are already ready." : "You were not ready.",
			EFAC_ALL, true, true, "#D1A04A");
		return true;
	}

	// A player un-readying after an admin forced everyone ready has to drop the latch, or
	// the round would start anyway and the message would be a lie.
	if (!bWantReady)
		AdminModDWShared().bAdminModDWForcedReady = false;

	AdminModDWAnnounceReady(PC.PlayerReplicationInfo.PlayerName
		@ (bWantReady ? "is ready" : "is NOT ready") @ AdminModDWReadyProgress(),
		bWantReady ? "#4CC964" : "#D1A04A");

	AdminModDWAudit(bWantReady ? "PLAYER_READY" : "PLAYER_UNREADY",
		PC.PlayerReplicationInfo.PlayerName @ AdminModDWReadyProgress());

	return true;
}

/** Shared state lives on the listener, so two admins cannot each keep their own copy. */
function AdminModDWRCon AdminModDWShared()
{
	return (ParentLink != none) ? ParentLink : self;
}

/**
 * The listener is the one AdminModDWRCon that is not a session. Found by sweep rather than
 * read off GameInfo.RemoteConsole, which cannot be trusted -- see AdminModDWRConSession.
 */
function AdminModDWRCon AdminModDWFindListener()
{
	local AdminModDWRCon RCon;

	foreach WorldInfo.AllActors(class'AdminModDWRCon', RCon)
	{
		if (AdminModDWRConSession(RCon) == none)
			return RCon;
	}

	return none;
}

/**
 * AOCRCon leaves AcceptClass unset, so the listening link takes the one connection itself
 * and every later client is dropped at auth. Setting it makes TcpLink spawn a session per
 * connection, each with its own RConState -- many clients, still one port.
 */
event PostBeginPlay()
{
	super.PostBeginPlay();
	AcceptClass = class'AdminModDWRConSession';
	LogAlwaysInternal("[AdminModDWRCon] listener up, AcceptClass=" $ string(AcceptClass));
}

function AdminModDWRegisterSession(AdminModDWRCon Session)
{
	Sessions[Sessions.Length] = Session;
	LogAlwaysInternal("[AdminModDWRCon] session opened (" $ Sessions.Length $ " live)");
}

function AdminModDWUnregisterSession(AdminModDWRCon Session)
{
	local int i;

	i = Sessions.Find(Session);
	if (i == INDEX_NONE)
		return;

	Sessions.Remove(i, 1);
	LogAlwaysInternal("[AdminModDWRCon] session closed (" $ Sessions.Length $ " live)");
}

/**
 * On a session this is that client's socket, so opcode handlers reply only to the client
 * that asked. On the listener it fans out -- that is the path every vanilla GameEvent_*
 * push already takes, so none of them need overriding.
 *
 * AOCRCon.SendPacket DRAINS the packet (Packet.Buffer.Remove after each SendBinary), so
 * the buffer has to be refilled per recipient or only the first session sees anything.
 */
function SendPacket(AOCRConPacket Packet)
{
	local int i;
	local array<byte> Payload;

	if (ParentLink != none)
	{
		super.SendPacket(Packet);
		return;
	}

	Payload = Packet.Buffer;

	for (i = Sessions.Length - 1; i >= 0; i--)
	{
		if (Sessions[i] == none)
		{
			Sessions.Remove(i, 1);
			continue;
		}

		if (Sessions[i].RConState != RCON_Connected)
			continue;

		Packet.Buffer = Payload;
		Sessions[i].SendPacket(Packet);
	}
}

/**
 * One place for "an admin did something". Logs it and puts it on the wire.
 * LogAlwaysInternal rather than the log macro: FINAL_RELEASE builds make LogInternal
 * private and the macro stops compiling.
 */
function AdminModDWAudit(string Action, string Detail)
{
	local AOCRConPacket Packet;

	LogAlwaysInternal("[AdminModDWRCon]" @ Action @ "|" @ Detail);

	Packet = new class'AOCRConPacket';
	Packet.SetMessageType(RCONX_ADMIN_AUDIT);
	Packet.AddString(Action);
	Packet.AddString(Detail);

	// Route via the listener so every connected admin sees it, not just the issuer.
	AdminModDWShared().SendPacket(Packet);
}

/**
 * Bots have no Steam ID, so stamp {A=0, B=PlayerID} like vanilla does at AOCRCon.uc:352 --
 * except that block is inside a notdefined(FINAL_RELEASE) guard, so shipped builds lose it.
 * Real SteamID64s never have a zero high half, so there is no collision.
 */
function EnsureUniqueId(PlayerReplicationInfo PRI)
{
	if (PRI == none)
		return;

	if (PRI.UniqueId.Uid.A == 0 && PRI.UniqueId.Uid.B == 0)
	{
		PRI.UniqueId.Uid.A = 0;
		PRI.UniqueId.Uid.B = PRI.PlayerID;
	}
}

/**
 * GetPlayerControllerFromGUID that also finds bots. Use for anything needing only a Pawn;
 * anything that talks to a client must keep using the PlayerController version.
 */
function Controller GetControllerFromGUID(QWord UniqueId)
{
	local Controller C;

	foreach WorldInfo.AllControllers(class'Controller', C)
	{
		if (C.PlayerReplicationInfo == none)
			continue;

		if (C.PlayerReplicationInfo.UniqueId.Uid == UniqueId)
			return C;
	}

	return none;
}

/** Stamp bots before the connect event goes out, so the client sees them from the start. */
function GameEvent_PlayerConnect(PlayerReplicationInfo PRI)
{
	EnsureUniqueId(PRI);
	AdminModDWReapplyMute(PRI);
	super.GameEvent_PlayerConnect(PRI);
}

/** Name for a uid we may or may not still have a controller for. */
function string DescribePlayer(QWord PlayerId)
{
	local AOCPlayerController PC;

	PC = GetPlayerControllerFromGUID(PlayerId);
	if (PC != none && PC.PlayerReplicationInfo != none)
		return PC.PlayerReplicationInfo.PlayerName;

	return "<unknown uid>";
}

/** "teams here are 0 (Blue), 1 (Red)" -- for a refusal that tells you what to do instead. */
function string AdminModDWDescribeTeams(AOCGame Game)
{
	local AOCTeamInfo TI;
	local string Out;
	local int i, Count;

	if (Game == none)
		return "no game to ask";

	for (i = 0; i < Game.Teams.Length; i++)
	{
		TI = AOCTeamInfo(Game.Teams[i]);
		if (TI == none || AOCTeamInfo_Spectators(TI) != none)
			continue;

		if (Count > 0)
			Out $= ", ";
		Out $= i $ " (" $ TI.GetHumanReadableName() $ ")";
		Count++;
	}

	if (Count == 0)
		return "this mode has no playable teams";

	return (Count == 1 ? "the only team here is " : "teams here are ") $ Out;
}

/** Same idea as DescribePlayer, but when the controller is already resolved. */
// Controller rather than AOCPlayerController so bots describe too.
function string DescribeController(Controller PC)
{
	if (PC != none && PC.PlayerReplicationInfo != none)
		return PC.PlayerReplicationInfo.PlayerName;

	return "<unknown player>";
}

/**
 * Extended opcodes are handled here; everything else falls through to vanilla.
 *
 * Deliberately checks RCON_Connected first. Vanilla's HandleMessage closes the
 * connection on any non-PASSWORD packet while still authenticating, and that behaviour
 * must survive -- an unauthenticated peer must not reach any of this.
 */
function HandleMessage(AOCRConPacket Packet)
{
	// Vanilla opcode 20 is intercepted rather than extended: AOCAccessControl.UnbanByUID
	// removes the entry from the in-memory array and never calls SaveConfig(), so the ban
	// is still in the ini and returns on the next server start. See HandleUnbanFixed.
	if (RConState == RCON_Connected && Packet.MessageType == MessageType.UNBAN_PLAYER)
	{
		HandleUnbanFixed(Packet);
		return;
	}

	// Vanilla opcode 7 is intercepted for the same reason: AOCRCon routes SAY_ALL_BIG to
	// the same HandleSayAll as SAY_ALL, so "big" was only ever a second chat line.
	if (RConState == RCON_Connected && Packet.MessageType == MessageType.SAY_ALL_BIG)
	{
		HandleSayAllBig(Packet);
		return;
	}

	if (RConState == RCON_Connected && Packet.MessageType >= RCONX_PING_EXTENDED)
	{
		switch (Packet.MessageType)
		{
			case RCONX_CHANGE_SCORE:          HandleChangeScore(Packet);        return;
			case RCONX_KILL_PLAYER:           HandleKillPlayer(Packet);         return;
			case RCONX_INEBRIATE:             HandleInebriate(Packet);          return;
			case RCONX_CHANGE_GAME_PASSWORD:  HandleChangeGamePassword(Packet); return;
			case RCONX_CONSOLE_COMMAND:       HandleConsoleCommand(Packet);     return;
			case RCONX_PLAYER_LIST_REQUEST:   HandlePlayerListRequest();        return;
			case RCONX_SET_TEAM:              HandleSetTeam(Packet);            return;
			case RCONX_FORCE_SPECTATE:        HandleForceSpectate(Packet);      return;
			case RCONX_SET_TEAM_SCORE:        HandleSetTeamScore(Packet);       return;
			case RCONX_SERVER_INFO_REQUEST:   SendServerInfo();                 return;
			case RCONX_BAN_LIST_REQUEST:      HandleBanListRequest();           return;
			case RCONX_MUTE_PLAYER:           HandleMutePlayer(Packet);         return;
			case RCONX_MUTE_LIST_REQUEST:     HandleMuteListRequest();          return;
			case RCONX_SET_PAUSE:             HandleSetPause(Packet);           return;
			case RCONX_END_MATCH:             HandleEndMatch(Packet);           return;
			case RCONX_SET_AUTOBALANCE:       HandleSetAutoBalance(Packet);     return;
			case RCONX_SET_GAME_SPEED:        HandleSetGameSpeed(Packet);       return;
			case RCONX_RESTART_MATCH:         HandleRestartMatch();             return;
			case RCONX_SOBER_PLAYER:          HandleSober(Packet);              return;
			case RCONX_SET_TOURNAMENT:        HandleSetTournament(Packet);      return;
			case RCONX_READY_ALL:             HandleReadyAll(Packet);           return;
			case RCONX_SET_FROZEN:            HandleSetFrozen(Packet);          return;
			case RCONX_SET_CLASS:             HandleSetClass(Packet);           return;
			case RCONX_LOADOUT_REQUEST:       HandleLoadoutRequest(Packet);     return;
			case RCONX_SET_LOADOUT:           HandleSetLoadout(Packet);         return;
			case RCONX_PLAYER_POS_REQUEST:    SendPlayerPositions();            return;
			case RCONX_TELEPORT:              HandleTeleport(Packet);           return;
			case RCONX_SLAP:                  HandleSlap(Packet);               return;
			default:
				// Unknown opcode from a client newer than this server. Ignore it
				// rather than dropping the connection.
				LogAlwaysInternal("[AdminModDWRCon] ignoring unknown opcode" @ Packet.MessageType);
				return;
		}
	}

	super.HandleMessage(Packet);
}

/**
 * Vanilla pushes MAP_CHANGED from AOCGame.ProcessServerTravel, before the new level is up,
 * so GetCurrentMap() resolves against the map being left -- and returns "" outright when
 * MapCycleIndex is INDEX_NONE and MapList[-1] yields an empty string. Drop the empty one;
 * AdminModDWGame re-announces once the new map is actually current.
 */
function GameEvent_MapChanged(string mapName, int mapIndex)
{
	if (mapName == "")
		return;

	super.GameEvent_MapChanged(mapName, mapIndex);
}

/* ============================ ChivAdmin parity ============================== */

/** 24: set a player's score. */
function HandleChangeScore(AOCRConPacket Packet)
{
	local QWord PlayerId;
	local int NewScore;
	local AOCPlayerController PC;

	PlayerId = Packet.GetGUID();
	NewScore = Packet.GetInt();

	PC = GetPlayerControllerFromGUID(PlayerId);
	if (PC == none || PC.PlayerReplicationInfo == none)
		return;

	PC.PlayerReplicationInfo.Score = NewScore;
	PC.PlayerReplicationInfo.bNetDirty = true;
	AdminModDWAudit("CHANGE_SCORE", PC.PlayerReplicationInfo.PlayerName @ "->" @ NewScore);
}

/** 25: kill a player where they stand. */
function HandleKillPlayer(AOCRConPacket Packet)
{
	local QWord PlayerId;
	local Controller C;

	PlayerId = Packet.GetGUID();

	C = GetControllerFromGUID(PlayerId);   // Controller-level so bots can be slain.

	if (C == none || C.Pawn == none)
		return;

	AdminModDWAudit("KILL_PLAYER", DescribeController(C));
	C.Pawn.Died(C, class'AOCDmgType_Generic', C.Pawn.Location);
}

/** 26: the drunk screen effect. AOCPlayerController.ClientInebriate drives the HUD. */
function HandleInebriate(AOCRConPacket Packet)
{
	local QWord PlayerId;
	local AOCPlayerController PC;

	PlayerId = Packet.GetGUID();
	PC = GetPlayerControllerFromGUID(PlayerId);
	if (PC == none)
		return;

	AdminModDWAudit("INEBRIATE", PC.PlayerReplicationInfo.PlayerName);

	// ClientInebriate is the whole job. EnableDrunkSoundMode must NOT be called from here:
	// it is a plain function, so on an RCON command it runs on the SERVER's copy of the
	// controller, where it sets a repeating timer that reaches for an audio device the
	// dedicated server does not have. AOCBaseHUD already drives the sound mode on the
	// player's own machine, from its fade in UpdateDrunkEffect.
	//
	// AdminModDWPlayerController.ClientInebriate adds the drunk post-process chain when
	// the map has none. Deadliest Warrior keeps the same drunkeffect / blackout nodes as
	// the base game (AOCBaseHUD.uc:1351), so the same approach carries over.
	PC.ClientInebriate(true);
}

/**
 * 48: undo 26. ChivAdmin never had this -- its Inebriate command carries only a UID and
 * is one-way, so the effect lasted until the player respawned. Kept as its own opcode
 * rather than adding a flag to 26, so 26 stays wire-compatible with a ChivAdmin client.
 */
function HandleSober(AOCRConPacket Packet)
{
	local QWord PlayerId;
	local AOCPlayerController PC;

	PlayerId = Packet.GetGUID();
	PC = GetPlayerControllerFromGUID(PlayerId);
	if (PC == none)
	{
		AdminModDWAudit("SOBER_FAILED", DescribePlayer(PlayerId) @ "- no player controller with that id");
		return;
	}

	AdminModDWAudit("SOBER", PC.PlayerReplicationInfo.PlayerName);
	PC.ClientInebriate(false);
}

/** 27: set (or clear, with an empty string) the server's join password. */
function HandleChangeGamePassword(AOCRConPacket Packet)
{
	local string NewPassword;

	NewPassword = Packet.GetString();

	if (WorldInfo.Game == none || WorldInfo.Game.AccessControl == none)
		return;

	WorldInfo.Game.AccessControl.SetGamePassword(NewPassword);

	// Never log the password itself.
	AdminModDWAudit("CHANGE_GAME_PASSWORD", (NewPassword == "") ? "cleared" : "set");
}

/** True if Command's first token is on AdminModDWBlockedConsoleCommands. */
function bool IsConsoleCommandBlocked(string Command)
{
	local string Verb;
	local int i, SpacePos;

	Verb = Locs(Command);

	while (Left(Verb, 1) == " " || Left(Verb, 1) == Chr(9))
		Verb = Mid(Verb, 1);

	SpacePos = InStr(Verb, " ");
	if (SpacePos != INDEX_NONE)
		Verb = Left(Verb, SpacePos);

	if (Verb == "")
		return false;

	for (i = 0; i < AdminModDWBlockedConsoleCommands.Length; i++)
	{
		if (Locs(AdminModDWBlockedConsoleCommands[i]) == Verb)
			return true;
	}

	return false;
}

/**
 * 28: run a console command. The most powerful thing here, hence the loudest audit.
 *
 * Scope 1 targets the SERVER-SIDE controller for that player, so it runs server
 * functions and admin execs against them. It does not execute on their machine.
 */
function HandleConsoleCommand(AOCRConPacket Packet)
{
	local QWord PlayerId;
	local int Scope;
	local string Command;
	local AOCPlayerController PC;
	local int Count;

	PlayerId = Packet.GetGUID();
	Scope    = Packet.GetInt();
	Command  = Packet.GetString();

	// All three scopes run in the server's process, so one check covers them.
	if (IsConsoleCommandBlocked(Command))
	{
		AdminModDWAudit("CONSOLE_COMMAND(blocked)", Command);
		SendConsoleResult(Command, "Blocked: this command would take the server down."
			@ "Edit AdminModDWBlockedConsoleCommands in UDKGame.ini to change the list.");
		return;
	}

	switch (Scope)
	{
		case SCOPE_GAME:
			AdminModDWAudit("CONSOLE_COMMAND(game)", Command);
			if (WorldInfo.Game != none)
				SendConsoleResult(Command, WorldInfo.Game.ConsoleCommand(Command));
			break;

		case SCOPE_PLAYER:
			PC = GetPlayerControllerFromGUID(PlayerId);
			if (PC == none)
				return;
			AdminModDWAudit("CONSOLE_COMMAND(player)", DescribePlayer(PlayerId) @ ":" @ Command);
			SendConsoleResult(Command, PC.ConsoleCommand(Command));
			break;

		case SCOPE_ALL_PLAYERS:
			foreach WorldInfo.AllControllers(class'AOCPlayerController', PC)
			{
				PC.ConsoleCommand(Command);
				Count++;
			}
			AdminModDWAudit("CONSOLE_COMMAND(all)", Command @ "on" @ Count @ "players");
			break;
	}
}

/**
 * 23: the richer per-player ping event, sent at vanilla's own ping cadence.
 *
 * Replaces vanilla opcode 22 rather than sitting alongside it, which is the same swap the
 * ChivAdmin mutator made, and the field order matches theirs so a ChivAdmin client reads
 * it unchanged.
 *
 * This overrides the vanilla hook deliberately: GameEvent_UpdatePing is the ONLY ping
 * entry point the game calls, so a new differently-named function here would never run.
 *
 * DW delta: Deadliest Warrior's AOCPRI has no IdleTime field (the base game added it
 * later), so idle seconds are computed on the server from PlayerController.LastActiveTime
 * -- the same value AOCLTS.uc:413 uses to kick idlers. The field keeps its wire position
 * and its units, so the client needs no change.
 */
function GameEvent_UpdatePing(PlayerReplicationInfo PRI, int NewPing)
{
	local AOCRConPacket Packet;
	local AOCPRI APRI;
	local PlayerController PC;
	local int IdleSeconds;

	APRI = AOCPRI(PRI);

	PC = PlayerController(PRI.Owner);
	if (PC != none && PC.LastActiveTime > 0.0)
		IdleSeconds = Max(0, int(WorldInfo.TimeSeconds - PC.LastActiveTime));

	Packet = new class'AOCRConPacket';
	Packet.SetMessageType(RCONX_PING_EXTENDED);
	Packet.AddQWord(PRI.UniqueId.Uid);
	Packet.AddInt(NewPing);
	Packet.AddInt(int(PRI.Score));
	Packet.AddInt(IdleSeconds);
	Packet.AddInt((APRI != none) ? APRI.NumKills : 0);
	Packet.AddInt((APRI != none) ? APRI.TeamDamageDealt : 0);
	Packet.AddInt((APRI != none) ? APRI.MyRank : 0);
	SendPacket(Packet);
}

/* ============================ AdminMod additions ============================= */

/**
 * 29 -> a burst of 30s then a 31.
 * ChivAdmin's PING event only carries uid and ping; this is the whole scoreboard.
 * NumKills rather than Kills: AOCPRI comments that Kills is not replicated.
 */
function HandlePlayerListRequest()
{
	local PlayerReplicationInfo PRI;
	local AOCRConPacket Packet;
	local int i;

	if (WorldInfo.GRI == none)
	{
		AdminModDWAudit("PLAYER_LIST_FAILED", "no GameReplicationInfo yet");
		Packet = new class'AOCRConPacket';
		Packet.SetMessageType(RCONX_PLAYER_LIST_END);
		SendPacket(Packet);
		return;
	}

	for (i = 0; i < WorldInfo.GRI.PRIArray.Length; i++)
	{
		PRI = WorldInfo.GRI.PRIArray[i];
		if (PRI == none)
			continue;

		// Bots present before RCON connected never fired the connect event.
		EnsureUniqueId(PRI);

		SendPlayerInfo(PRI);
	}

	Packet = new class'AOCRConPacket';
	Packet.SetMessageType(RCONX_PLAYER_LIST_END);
	Packet.AddInt(WorldInfo.GRI.PRIArray.Length);
	SendPacket(Packet);
}

/**
 * 30: uid, name, team, score, deaths, kills, ping, health, teamDamage, class, spectator
 *
 * DW delta: the class name is one of the six Deadliest Warrior families
 * (CDWFamilyInfo_Samurai / Spartan / Viking / Knight / Ninja / Pirate) rather than the
 * base game's Agatha/Mason pair, and MyFamilyInfo is a class reference here rather than
 * an instance. The wire field is still the class name string.
 */
function SendPlayerInfo(PlayerReplicationInfo PRI)
{
	local AOCRConPacket Packet;
	local AOCPRI APRI;
	local string ClassName;

	APRI = AOCPRI(PRI);

	ClassName = "";
	if (APRI != none && APRI.MyFamilyInfo != none)
		ClassName = string(APRI.MyFamilyInfo.Name);

	Packet = new class'AOCRConPacket';
	Packet.SetMessageType(RCONX_PLAYER_INFO);
	Packet.AddQWord(PRI.UniqueId.Uid);
	Packet.AddString(PRI.PlayerName);
	Packet.AddInt((PRI.Team != none) ? PRI.Team.TeamIndex : -1);
	Packet.AddInt(int(PRI.Score));
	Packet.AddInt(PRI.Deaths);
	Packet.AddInt((APRI != none) ? APRI.NumKills : 0);
	// PRI.Ping is quarter-ms (PlayerController.ServerUpdatePing); opcode 23 sends raw ms.
	// Scale so both agree. Saturates at 1000ms.
	Packet.AddInt(PRI.Ping * 4);
	Packet.AddInt((APRI != none) ? APRI.CurrentHealth : 0);
	Packet.AddInt((APRI != none) ? APRI.TeamDamageDealt : 0);
	Packet.AddString(ClassName);
	Packet.AddInt((APRI != none && APRI.bIsVoluntarySpectator) ? 1 : 0);
	SendPacket(Packet);
}

/** 32: move a player to a team. */
function HandleSetTeam(AOCRConPacket Packet)
{
	local QWord PlayerId;
	local int NewTeam;
	local AOCPlayerController PC;

	PlayerId = Packet.GetGUID();
	NewTeam  = Packet.GetInt();

	PC = GetPlayerControllerFromGUID(PlayerId);
	if (PC == none || WorldInfo.Game == none)
		return;

	AdminModDWForceTeam(PC, NewTeam);
}

/**
 * Move a player to another team.
 *
 * DW delta, and this is the big one. In the base game a family IS a faction -- an Agatha
 * Knight and a Mason Knight are different AOCFamilyInfo objects, AOCGame.ChangeTeam
 * re-resolves the team from CurrentFamilyInfo.FamilyFaction and so always refuses, and the
 * only working swap is to walk AOCGRI.FamilyInfos (0-4 Agatha, 5-9 Mason) and rebuild the
 * class. Deadliest Warrior has none of that: teams are colours, the six warrior families
 * are team-independent, CurrentFamilyInfo is a class reference, and SetNewClass takes the
 * destination TeamInfo explicitly. So the swap is just SetNewClass with the new team --
 * the same call AOCGame.PerformDeathBasedAB (AOCGame.uc:5398) makes.
 *
 * bAutoBalance=true refunds the death the switch causes; bForceSwitch=true re-picks a
 * loadout legal for the destination and lands the change now rather than on next respawn.
 * AOCTeamObjectivePC.SetNewClass swallows bForceSwitch (it forwards "bNegPoints,,"), so in
 * Team Objective the team change still lands but the pawn is not killed to apply it.
 */
function AdminModDWForceTeam(AOCPlayerController PC, int NewTeam)
{
	local AOCGame Game;
	local class<AOCFamilyInfo> Fam;
	local AOCTeamInfo DestTeam;
	local int i;

	Game = AOCGame(WorldInfo.Game);
	if (Game == none)
	{
		AdminModDWAudit("SET_TEAM_FAILED", DescribeController(PC) @ "- the game is not an AOCGame");
		return;
	}

	if (NewTeam < 0 || NewTeam >= Game.Teams.Length || Game.Teams[NewTeam] == none)
	{
		// Not a bounds bug: the slot exists but is None. Teams is length 7 on every mode
		// (InitTeams makes the spectator team at index 6 first, growing the array), and only
		// 0..NumTeams-1 are filled. FFA and Duel run NumTeams=1, so team 1 really is not
		// there -- which is why "move to red" cannot work on an FFA map however the base
		// game behaves. AdminMod appears to manage it on Medieval Warfare only because it
		// changes the player's FACTION through AOCGRI.FamilyInfos instead of touching Teams.
		AdminModDWAudit("SET_TEAM_FAILED", DescribeController(PC) @ "- there is no team"
			@ NewTeam @ "on this map;" @ AdminModDWDescribeTeams(Game));
		return;
	}

	DestTeam = AOCTeamInfo(Game.Teams[NewTeam]);
	if (DestTeam == none || AOCTeamInfo_Spectators(DestTeam) != none)
	{
		AdminModDWAudit("SET_TEAM_FAILED", DescribeController(PC)
			@ "- team" @ NewTeam @ "is the spectator team; use opcode 33 instead");
		return;
	}

	if (PC.PlayerReplicationInfo != none && PC.PlayerReplicationInfo.Team != none
		&& PC.PlayerReplicationInfo.Team.TeamIndex == NewTeam)
	{
		AdminModDWAudit("SET_TEAM_NOOP", DescribeController(PC)
			@ "- already on" @ DestTeam.GetHumanReadableName());
		return;
	}

	Fam = PC.CurrentFamilyInfo;

	// Keep their class where the destination allows it, otherwise take the first class it
	// does allow -- AllowedClasses is per-team and a map can restrict it.
	if (Fam == none || Fam == class'AOCFamilyInfo_None'
		|| !Bool(DestTeam.AllowedClasses[Fam.default.ClassReference]))
	{
		Fam = none;
		for (i = 0; i < ECLASS_Random; i++)
		{
			if (Bool(DestTeam.AllowedClasses[i]))
			{
				Fam = class'AOCPawn'.default.PlayerClasses[EAOCClass(i)];
				break;
			}
		}
	}

	if (Fam == none)
	{
		AdminModDWAudit("SET_TEAM_FAILED", DescribeController(PC)
			@ "- team" @ NewTeam @ "allows no classes");
		return;
	}

	PC.SetNewClass(Fam, DestTeam, true, true);

	AdminModDWAudit("SET_TEAM", DescribeController(PC) @ "->"
		@ DestTeam.GetHumanReadableName() @ "as" @ string(Fam.Name));
}

/**
 * 7: the big broadcast.
 *
 * DW delta: Deadliest Warrior has no ClientShowLocalizedHeaderText. Its equivalent is
 * ReceiveLocalizedHeaderText (AOCPlayerController.uc:3378), a reliable client function
 * that drives the same large header banner and takes a display time. Chat still gets the
 * line too, because the banner clears itself.
 */
function HandleSayAllBig(AOCRConPacket Packet)
{
	local AOCPlayerController PC;
	local AOCGame Game;
	local string Message;
	local int Shown;

	Message = Packet.GetString();
	if (Message == "")
	{
		AdminModDWAudit("SAY_ALL_BIG_FAILED", "empty message");
		return;
	}

	foreach WorldInfo.AllControllers(class'AOCPlayerController', PC)
	{
		// bOverride=true so an admin announcement jumps the header queue rather than
		// waiting behind spawn and objective banners.
		PC.ReceiveLocalizedHeaderText(Message, 6.0, true);
		Shown++;
	}

	Game = AOCGame(WorldInfo.Game);
	if (Game != none)
		Game.BroadcastMessage(none, Message, EFAC_ALL, true);

	AdminModDWAudit("SAY_ALL_BIG", Message @ "->" @ string(Shown) @ "players");
}

/**
 * 20 (vanilla): unban by UID, but persisted.
 *
 * AOCAccessControl.UnbanByUID never calls SaveConfig (AddBan does), so the ban returns
 * on restart. Removing it here lets us save, and report whether anything was removed.
 */
function HandleUnbanFixed(AOCRConPacket Packet)
{
	local UniqueNetId NetID;
	local AOCAccessControl AC;
	local string Removed;
	local int i, PolicyIndex;

	NetID.Uid = Packet.GetGUID();

	if (WorldInfo.Game == none)
		return;

	AC = AOCAccessControl(WorldInfo.Game.AccessControl);
	if (AC == none)
	{
		AdminModDWAudit("UNBAN_FAILED", "no AOCAccessControl");
		return;
	}

	// Find it first purely so the audit line can name who was unbanned; the removal
	// itself goes through the stock function rather than poking AC.Bans directly.
	for (i = 0; i < AC.Bans.Length; i++)
	{
		if (AC.Bans[i].NetID == NetID)
		{
			Removed = AC.Bans[i].PlayerName @ "(" $ AC.Bans[i].NetIDAsString $ ")";
			break;
		}
	}

	// Not in Bans, but it may still be in the stock uid list that Super.IsIDBanned
	// enforces. UnbanByUID only touches Bans, so without this an entry the ban list now
	// shows as "(uid ban list)" could be unbanned forever and never actually lift.
	if (Removed == "")
	{
		for (i = 0; i < AC.BannedIDs.Length; i++)
		{
			if (!(AC.BannedIDs[i] == NetID))
				continue;

			Removed = "(uid ban list) (" $ class'OnlineSubsystem'.static.UniqueNetIdToString(NetID) $ ")";

			// KickBanPlayer wrote a DENY line alongside this uid, so lifting the ban has to
			// take both or the ini fills with orphans. Resolved before the removal, since the
			// pairing test compares the two array lengths.
			PolicyIndex = AdminModDWPoliciesPairBans(AC) ? AdminModDWNthDenyPolicy(AC, i) : INDEX_NONE;

			AC.BannedIDs.Remove(i, 1);
			if (PolicyIndex != INDEX_NONE)
			{
				Removed @= "and its policy line" @ AC.IPPolicies[PolicyIndex];
				AC.IPPolicies.Remove(PolicyIndex, 1);
			}

			AC.SaveConfig();
			AdminModDWAudit("UNBAN", Removed);
			return;
		}
	}

	if (Removed == "")
	{
		AdminModDWAudit("UNBAN_FAILED", "no ban matching uid" @ NetID.Uid.A @ NetID.Uid.B
			@ "- request the ban list (opcode 39) and unban with a uid from it");
		return;
	}

	AC.UnbanByUID(NetID);

	// The bit vanilla forgets. Without this the array is clean in memory but the ini
	// still lists the ban, so it comes straight back on the next server start.
	AC.SaveConfig();

	AdminModDWAudit("UNBAN", Removed);
}

/** 33: force a player into spectate. Mirrors AOCPlayerController's own admin path. */
function HandleForceSpectate(AOCRConPacket Packet)
{
	local QWord PlayerId;
	local AOCPlayerController PC;

	PlayerId = Packet.GetGUID();
	PC = GetPlayerControllerFromGUID(PlayerId);
	if (PC == none)
		return;

	AdminModDWAudit("FORCE_SPECTATE", DescribePlayer(PlayerId));
	PC.JoinSpectatorTeam();
}

/**
 * 34: set a team's score.
 *
 * LTS is the odd one: AOCLTS.RoundScores is authoritative, AOCLTSGRI.RoundsWon is drawn,
 * and Teams[].Score is a mirror rewritten from RoundScores at every round boundary
 * (AOCLTS.uc:192-195, :301-303). Writing the mirror alone is silently discarded. All three
 * here. RoundsWon is a fixed-size array indexed by EAOCFaction in this SDK, not a dynamic
 * one, so it is bounds-checked against RoundScores instead of its own Length.
 */
function HandleSetTeamScore(AOCRConPacket Packet)
{
	local int TeamIndex, NewScore, Goal;
	local AOCLTS LTS;

	TeamIndex = Packet.GetInt();
	NewScore  = Packet.GetInt();

	if (WorldInfo.GRI == none || TeamIndex < 0 || TeamIndex >= WorldInfo.GRI.Teams.Length)
		return;
	if (WorldInfo.GRI.Teams[TeamIndex] == none)
		return;

	WorldInfo.GRI.Teams[TeamIndex].Score = NewScore;
	WorldInfo.GRI.Teams[TeamIndex].bForceNetUpdate = true;

	LTS = AOCLTS(WorldInfo.Game);
	if (LTS != none && TeamIndex < LTS.RoundScores.Length)
	{
		LTS.RoundScores[TeamIndex] = NewScore;

		if (AOCLTSGRI(LTS.GameReplicationInfo) != none)
		{
			AOCLTSGRI(LTS.GameReplicationInfo).RoundsWon[TeamIndex] = NewScore;
			LTS.GameReplicationInfo.bForceNetUpdate = true;
		}

		// AOCLTS.uc:309 tests RoundScores[winner] == GoalScore AFTER incrementing it, so a
		// team parked ON the goal steps over it and the match never ends. GoalScore - 1 is
		// what makes the next round decisive.
		Goal = LTS.GoalScore;
		if (Goal > 0 && NewScore >= Goal)
		{
			AdminModDWAudit("SET_TEAM_SCORE_WARNING",
				"team" @ TeamIndex @ "is at or past the goal of" @ Goal
				$ " - the end-of-round check is an exact match, so set" @ (Goal - 1)
				@ "if the next round should decide it");
		}
	}

	AdminModDWAudit("SET_TEAM_SCORE", "team" @ TeamIndex @ "->" @ NewScore
		@ (LTS != none ? "(rounds won)" : ""));
}

/**
 * 37: map, player count, match state, and who is answering.
 *
 * The last two fields are an ADDITION to the layout AdminMod ships: the mod name and the
 * game. They exist so a client can stop guessing which Chivalry it is talking to. The two
 * games share the protocol byte for byte, but not the meaning of every number in it -- team 1
 * is Mason on Medieval Warfare and Red here, and class index 2 is Vanguard there and Viking
 * here -- so a client that labels its buttons from the wrong table sends the right index with
 * the wrong promise.
 *
 * Appending is safe in both directions. A client that reads only the first five fields
 * ignores the rest, and a client that looks for these two treats their absence as
 * "an extended server that predates this field", which can only be AdminMod / XangMod /
 * BangMod on Medieval Warfare -- AdminModDW has never shipped without them. A vanilla server
 * ignores opcode 36 entirely and answers nothing, which is a third, distinguishable case.
 */
function SendServerInfo()
{
	local AOCRConPacket Packet;

	Packet = new class'AOCRConPacket';
	Packet.SetMessageType(RCONX_SERVER_INFO);
	Packet.AddString(WorldInfo.GetMapName(true));
	Packet.AddInt((WorldInfo.Game != none) ? WorldInfo.Game.NumPlayers : 0);
	Packet.AddInt((WorldInfo.Game != none) ? WorldInfo.Game.MaxPlayers : 0);
	Packet.AddInt((WorldInfo.GRI != none && WorldInfo.GRI.bMatchHasBegun) ? 1 : 0);
	Packet.AddInt((WorldInfo.Game != none) ? WorldInfo.Game.NumSpectators : 0);

	// Which mod, then which game. Literals rather than ModDisplayString: that is a cosmetic
	// server-browser label an admin may well rename, and this is an identifier a client
	// branches on.
	Packet.AddString("AdminModDW");
	Packet.AddString("DeadliestWarrior");

	// Then the teams that actually exist right now, so a client can stop assuming there are
	// two of them. Deadliest Warrior runs anywhere from one to six: FFA and Duel force
	// NumTeams=1, the tutorial forces 6, everything else defaults to 2 and takes ?NumTeams=
	// on the command line, clamped 2-6 (AOCGame.uc:3916).
	AddTeamList(Packet);

	SendPacket(Packet);
}

/**
 * Appends: int count, then {int teamIndex, string name, string colourName, string colourHex}
 * per playable team.
 *
 * The colour is sent separately from the name on purpose, because on a multi-team map they
 * are usually NOT the same thing. `InitTeams` renames a team to its class whenever that team
 * is restricted to one -- `TeamName = "Team"$PlayerClassNames[Restriction]` -- so a six-team
 * Deadliest Warrior match reports "Vikings", "Ninjas", "Samurai" and so on, and the colour an
 * admin actually sees on the scoreboard appears nowhere in the name. Both are needed to point
 * at a team unambiguously.
 *
 * Hex is `TeamTextMarkupColor`, the colour vanilla itself uses for team-coloured text, rather
 * than the darker `TeamColor` used for cloth -- it is the one picked for legibility on a UI.
 *
 * Read straight off the live Teams array rather than from a table, because the answer is
 * per-map and per-command-line. Two traps it has to respect:
 *
 *  - Array position IS the team index (AOCGame.CreateTeam assigns Teams[TeamIndex]), but the
 *    array is NOT densely packed. InitTeams creates the spectator team FIRST, at
 *    EFAC_Spectator = 6, which grows the array to length 7; the loop then fills only
 *    0..NumTeams-1. So in FFA, Teams[1] through Teams[5] are None and Teams.Length is still
 *    7. Never infer the team count from Teams.Length.
 *  - The spectator team is skipped: joining it is opcode 33, not a team move.
 */
function AddTeamList(AOCRConPacket Packet)
{
	local AOCGame Game;
	local AOCTeamInfo TI;
	local int i, Count;

	Game = AOCGame(WorldInfo.Game);
	if (Game == none)
	{
		Packet.AddInt(0);
		return;
	}

	for (i = 0; i < Game.Teams.Length; i++)
	{
		TI = AOCTeamInfo(Game.Teams[i]);
		if (TI == none || AOCTeamInfo_Spectators(TI) != none)
			continue;
		Count++;
	}

	Packet.AddInt(Count);

	for (i = 0; i < Game.Teams.Length; i++)
	{
		TI = AOCTeamInfo(Game.Teams[i]);
		if (TI == none || AOCTeamInfo_Spectators(TI) != none)
			continue;

		Packet.AddInt(i);
		Packet.AddString(TI.GetHumanReadableName());
		Packet.AddString(AdminModDWTeamColorName(TI, i));
		Packet.AddString(TI.TeamTextMarkupColor);
	}
}

/**
 * "Blue", "Red", "White" ... -- EFAC_White is the pale one, which reads as grey on the
 * scoreboard shield but is White everywhere in the code (AOCTeamInfo_White). There is no
 * Grey team.
 *
 * Localized through vanilla's own helper so a non-English server reports its own words, with
 * the raw key as the fallback -- it is already an English colour word, so a missing
 * localization entry degrades to something readable rather than to an empty swatch label.
 */
function string AdminModDWTeamColorName(AOCTeamInfo TI, int TeamIndex)
{
	local string Localized;

	Localized = class'AOCTeamInfo'.static.GetLocalizedTeamColorNameFor(EAOCFaction(TeamIndex));

	if (Localized != "" && Left(Localized, 1) != "?")
		return Localized;

	return TI.TeamColorName;
}

/**
 * 38: hand back whatever the command printed. Vanilla discards ConsoleCommand's return,
 * so query commands were invisible. Empty results are still sent, so every request pairs.
 */
function SendConsoleResult(string Command, string Result)
{
	local AOCRConPacket Packet;

	Packet = new class'AOCRConPacket';
	Packet.SetMessageType(RCONX_CONSOLE_RESULT);
	Packet.AddString(Command);
	Packet.AddString(Result);
	SendPacket(Packet);
}

/* --- ban-list helpers: Chivalry keeps its bans in three places, see below --- */

/**
 * "DENY,<addr>" or "DENY;<addr>" -- the address may be empty. ACCEPT lines and anything
 * without a separator are not DENY policies.
 */
function bool AdminModDWIsDenyPolicy(string Policy)
{
	local int Sep;

	Sep = InStr(Policy, ",");
	if (Sep == INDEX_NONE)
		Sep = InStr(Policy, ";");

	return Sep != INDEX_NONE && Left(Policy, Sep) ~= "DENY";
}

/** The address half of a policy line, "" when the line carries none. */
function string AdminModDWPolicyAddress(string Policy)
{
	local int Sep;

	Sep = InStr(Policy, ",");
	if (Sep == INDEX_NONE)
		Sep = InStr(Policy, ";");

	return (Sep == INDEX_NONE) ? "" : Mid(Policy, Sep + 1);
}

/**
 * True when every banned uid has exactly one DENY line, i.e. the two arrays are in lockstep
 * and the Nth DENY line can be trusted to belong to the Nth banned uid.
 *
 * AOCAccessControl.KickBanPlayer appends "DENY," $ IP and then BannedIDs.AddItem in the same
 * call, so Chivalry writes them as a pair, in that order, every time. The address is empty in
 * practice because that function does Left(IP, InStr(IP, ":")) and a Steam socket address
 * carries no ":port" -- InStr returns -1 and Left(IP, -1) is "". Counting rather than assuming
 * keeps a hand-edited ini (an admin's own DENY line, say) from having the wrong entry removed.
 */
function bool AdminModDWPoliciesPairBans(AOCAccessControl AC)
{
	local int i, Denies;

	for (i = 0; i < AC.IPPolicies.Length; i++)
	{
		if (AdminModDWIsDenyPolicy(AC.IPPolicies[i]))
			Denies++;
	}

	return AC.BannedIDs.Length > 0 && Denies == AC.BannedIDs.Length;
}

/** Index into IPPolicies of the Nth DENY line, or INDEX_NONE. */
function int AdminModDWNthDenyPolicy(AOCAccessControl AC, int Ordinal)
{
	local int i, Seen;

	for (i = 0; i < AC.IPPolicies.Length; i++)
	{
		if (!AdminModDWIsDenyPolicy(AC.IPPolicies[i]))
			continue;

		if (Seen == Ordinal)
			return i;

		Seen++;
	}

	return INDEX_NONE;
}

/**
 * 39 -> a burst of 40s then a 41. Vanilla can unban but never shows the list, so you had
 * to know the uid.
 *
 * Three stores, all of them live, all of them reported here:
 *   AOCAccessControl.Bans        name, reason, duration. Written by AddBan/KickBanGlobal --
 *                                the RCON ban, votekick, the ping kick.
 *   Engine.AccessControl.BannedIDs   bare uids, written by the console "admin kickban" and by
 *                                AOCAccessControl.KickBanPlayer. Enforced, because
 *                                AOCAccessControl.IsIDBanned ends with Super.IsIDBanned.
 *   Engine.AccessControl.IPPolicies  DENY lines, enforced through Super.CheckIPPolicy.
 *
 * KickBanPlayer writes a DENY line and a BannedIDs entry together, so in practice the last
 * two pair up one-for-one and are reported as a single row.
 */
function HandleBanListRequest()
{
	local AOCAccessControl AC;
	local AOCRConPacket Packet;
	local QWord ZeroId;
	local UniqueNetId LegacyId;
	local string Policy;
	local bool bAlreadyListed, bPaired;
	local int i, j, PolicyIndex, Count, LegacyUids, LegacyIPs;

	if (WorldInfo.Game == none)
		return;

	AC = AOCAccessControl(WorldInfo.Game.AccessControl);
	if (AC == none)
	{
		// Terminate the burst anyway. Returning without a BAN_LIST_END leaves the client
		// waiting forever, which on screen is indistinguishable from an empty ban list.
		AdminModDWAudit("BAN_LIST_FAILED", "AccessControl is not an AOCAccessControl");
		Packet = new class'AOCRConPacket';
		Packet.SetMessageType(RCONX_BAN_LIST_END);
		Packet.AddInt(0);
		SendPacket(Packet);
		return;
	}

	for (i = 0; i < AC.Bans.Length; i++)
	{
		Packet = new class'AOCRConPacket';
		Packet.SetMessageType(RCONX_BAN_INFO);
		Packet.AddQWord(AC.Bans[i].NetID.Uid);
		Packet.AddString(AC.Bans[i].PlayerName);
		Packet.AddString(AC.Bans[i].Reason);
		Packet.AddInt(AC.Bans[i].DurationSeconds);
		Packet.AddString(AC.Bans[i].NetIDAsString);
		Packet.AddString(AC.Bans[i].IPPolicy);
		SendPacket(Packet);
		Count++;
	}

	// There is a SECOND live ban store. AOCAccessControl.IsIDBanned ends with
	// "return bBanned || Super.IsIDBanned(NetID)", so Engine.AccessControl.BannedIDs is
	// still enforced -- it just carries no name, reason or duration. AddBan/KickBanGlobal
	// (the RCON ban, votekick, ping kick) write to Bans; the console "admin kickban" and
	// AOCAccessControl.KickBanPlayer write to BannedIDs instead. Reporting only Bans meant
	// a server could be enforcing bans this list never showed.
	bPaired = AdminModDWPoliciesPairBans(AC);

	for (i = 0; i < AC.BannedIDs.Length; i++)
	{
		bAlreadyListed = false;
		for (j = 0; j < AC.Bans.Length; j++)
		{
			if (AC.Bans[j].NetID == AC.BannedIDs[i])
			{
				bAlreadyListed = true;
				break;
			}
		}

		if (bAlreadyListed)
			continue;

		// Show the paired DENY line in the IP column, but only when it names an address --
		// Chivalry writes a bare "DENY," for every Steam-socket ban and that is not worth a
		// column of noise.
		PolicyIndex = bPaired ? AdminModDWNthDenyPolicy(AC, i) : INDEX_NONE;
		Policy = "";
		if (PolicyIndex != INDEX_NONE && AdminModDWPolicyAddress(AC.IPPolicies[PolicyIndex]) != "")
			Policy = AC.IPPolicies[PolicyIndex];

		LegacyId = AC.BannedIDs[i];
		Packet = new class'AOCRConPacket';
		Packet.SetMessageType(RCONX_BAN_INFO);
		Packet.AddQWord(LegacyId.Uid);
		Packet.AddString("(uid ban list)");
		Packet.AddString("Banned by console kickban -- no name or reason recorded");
		Packet.AddInt(0);
		Packet.AddString(class'OnlineSubsystem'.static.UniqueNetIdToString(LegacyId));
		Packet.AddString(Policy);
		SendPacket(Packet);
		Count++;
		LegacyUids++;
	}

	// And a third store: DENY lines that belong to nobody. Super.CheckIPPolicy walks
	// IPPolicies, so these are live bans too. Skipped entirely when the arrays pair up,
	// since then every DENY line was already reported on its uid's row above.
	for (i = 0; !bPaired && i < AC.IPPolicies.Length; i++)
	{
		Policy = AC.IPPolicies[i];

		// An empty mask matches no address in Engine.AccessControl.CheckIPPolicy, so a bare
		// "DENY," is inert -- listing it as a ban would be a lie.
		if (!AdminModDWIsDenyPolicy(Policy) || AdminModDWPolicyAddress(Policy) == "")
			continue;

		bAlreadyListed = false;
		for (j = 0; j < AC.Bans.Length; j++)
		{
			if (AC.Bans[j].IPPolicy ~= Policy)
			{
				bAlreadyListed = true;
				break;
			}
		}

		if (bAlreadyListed)
			continue;

		Packet = new class'AOCRConPacket';
		Packet.SetMessageType(RCONX_BAN_INFO);
		Packet.AddQWord(ZeroId);
		Packet.AddString("(ip ban)");
		Packet.AddString("IP policy -- remove from IPPolicies in the server ini to lift");
		Packet.AddInt(0);
		Packet.AddString("");
		Packet.AddString(Policy);
		SendPacket(Packet);
		Count++;
		LegacyIPs++;
	}

	// One audit line per refresh, naming what each store holds. When the list looks empty
	// this is what says whether the server has nothing or the bans are somewhere we do not
	// read -- worth far more than guessing from a blank grid.
	AdminModDWAudit("BAN_LIST", "Bans=" $ AC.Bans.Length $ " BannedIDs=" $ AC.BannedIDs.Length
		$ " (" $ LegacyUids $ " extra) IPPolicies=" $ AC.IPPolicies.Length
		$ " (" $ LegacyIPs $ " loose DENY) paired=" $ (bPaired ? "yes" : "no") $ " sent=" $ Count);

	Packet = new class'AOCRConPacket';
	Packet.SetMessageType(RCONX_BAN_LIST_END);
	Packet.AddInt(Count);
	SendPacket(Packet);
}

/** 62: list the players currently muted, online or not. */
function HandleMuteListRequest()
{
	local AOCPlayerController PC;
	local AOCPRI APRI, Online;
	local AOCRConPacket Packet;
	local int i, Count, Live;

	for (i = 0; i < AdminModDWShared().Mutes.Length; i++)
	{
		Online = none;
		foreach WorldInfo.AllControllers(class'AOCPlayerController', PC)
		{
			APRI = AOCPRI(PC.PlayerReplicationInfo);
			if (APRI != none && APRI.UniqueId == AdminModDWShared().Mutes[i].NetID)
			{
				Online = APRI;
				break;
			}
		}

		Packet = new class'AOCRConPacket';
		Packet.SetMessageType(RCONX_MUTE_INFO);
		Packet.AddQWord(AdminModDWShared().Mutes[i].NetID.Uid);
		Packet.AddString((Online != none) ? Online.PlayerName : AdminModDWShared().Mutes[i].PlayerName);
		Packet.AddInt((Online != none && Online.Team != none) ? Online.Team.TeamIndex : -1);
		Packet.AddInt((Online != none) ? 1 : 0);
		Packet.AddInt(1);
		SendPacket(Packet);
		Count++;
	}

	// The ban list's problem again, in the other store. AOCPlayerController.AdminMutePlayer (DW's
	// name for it; Medieval Warfare calls it ServerAdminMutePlayer) writes AOCPRI.bIsAdminMuted
	// straight and never reaches the stored list, so an in-game mute was live and invisible here.
	// Reported with stored=0: real, but gone the moment that player disconnects.
	foreach WorldInfo.AllControllers(class'AOCPlayerController', PC)
	{
		APRI = AOCPRI(PC.PlayerReplicationInfo);
		if (APRI == none || !APRI.bIsAdminMuted)
			continue;

		if (AdminModDWFindMute(APRI.UniqueId) != INDEX_NONE)
			continue;

		Packet = new class'AOCRConPacket';
		Packet.SetMessageType(RCONX_MUTE_INFO);
		Packet.AddQWord(APRI.UniqueId.Uid);
		Packet.AddString(APRI.PlayerName);
		Packet.AddInt((APRI.Team != none) ? APRI.Team.TeamIndex : -1);
		Packet.AddInt(1);
		Packet.AddInt(0);
		SendPacket(Packet);
		Count++;
		Live++;
	}

	// Same reasoning as the ban list: say out loud what each store holds, so an empty grid can
	// be told apart from a request that never came back.
	AdminModDWAudit("MUTE_LIST", "stored=" $ AdminModDWShared().Mutes.Length $ " live-only=" $ Live $ " sent=" $ Count);

	Packet = new class'AOCRConPacket';
	Packet.SetMessageType(RCONX_MUTE_LIST_END);
	Packet.AddInt(Count);
	SendPacket(Packet);
}

/**
 * 42: admin text mute.
 *
 * Sets AOCPRI.bIsAdminMuted directly rather than calling AdminMutePlayer (DW's name for it;
 * Medieval Warfare calls it ServerAdminMutePlayer), which gates on the CALLER's
 * PlayerReplicationInfo.bAdmin -- the remote console has no PRI, so that path can never
 * authorise it. Authorisation here is the RCON password.
 *
 * The flag alone is not enough: vanilla only consults bIsAdminMuted client-side in
 * AOCPlayerController.ReceiveChatMessage, and that check is skipped for Steam friends of
 * the muted player and for the muted player's own copy of the message.
 * AdminModDWGame.BroadcastMessage drops the message server-side instead.
 */
function HandleMutePlayer(AOCRConPacket Packet)
{
	local QWord PlayerId;
	local bool bMute;
	local AOCPlayerController PC;
	local AOCPRI APRI;
	local string StoredName;
	local int i;

	PlayerId = Packet.GetGUID();
	bMute    = (Packet.GetInt() != 0);

	PC = GetPlayerControllerFromGUID(PlayerId);
	if (PC == none)
	{
		// Offline: no flag to set, but the stored entry still has to be clearable or a
		// mute outlives every chance to lift it.
		for (i = 0; i < AdminModDWShared().Mutes.Length; i++)
		{
			if (AdminModDWShared().Mutes[i].NetID.Uid != PlayerId)
				continue;

			StoredName = AdminModDWShared().Mutes[i].PlayerName;
			if (!bMute)
			{
				AdminModDWRememberMute(AdminModDWShared().Mutes[i].NetID, StoredName, false);
				AdminModDWAudit("UNMUTE_PLAYER", StoredName @ "(offline)");
			}
			return;
		}
		return;
	}

	APRI = AOCPRI(PC.PlayerReplicationInfo);
	if (APRI == none)
		return;

	APRI.bIsAdminMuted = bMute;
	APRI.bForceNetUpdate = true;
	AdminModDWRememberMute(APRI.UniqueId, APRI.PlayerName, bMute);
	AdminModDWAudit(bMute ? "MUTE_PLAYER" : "UNMUTE_PLAYER", APRI.PlayerName);
}

/* ======================= freeze, class, loadout, map ======================== */

/**
 * 60: send one player to another. Takes both ends because from here neither is "you".
 * Placement lives in AdminModDWAdminActions: SetLocation returns false when the spot is
 * occupied, so it rings the destination rather than dropping someone inside them.
 */
function HandleTeleport(AOCRConPacket Packet)
{
	local QWord MoverId, DestId;
	local Controller Mover, Dest;   // Controller-level so bots work either end.

	MoverId = Packet.GetGUID();
	DestId  = Packet.GetGUID();

	Mover = GetControllerFromGUID(MoverId);
	Dest  = GetControllerFromGUID(DestId);

	if (Mover == none || Dest == none)
		return;

	if (Mover == Dest)
	{
		AdminModDWAudit("TELEPORT_FAILED", DescribeController(Mover) @ "- cannot send a player to themselves");
		return;
	}

	if (Mover.Pawn == none || Dest.Pawn == none)
	{
		AdminModDWAudit("TELEPORT_FAILED",
			DescribeController(Mover) @ "->" @ DescribeController(Dest) @ "- both must be alive");
		return;
	}

	if (class'AdminModDWAdminActions'.static.Teleport(Mover.Pawn, Dest.Pawn))
		AdminModDWAudit("TELEPORT", DescribeController(Mover) @ "->" @ DescribeController(Dest));
	else
		AdminModDWAudit("TELEPORT_FAILED",
			DescribeController(Mover) @ "->" @ DescribeController(Dest) @ "- no free space there");
}

/** 61: launch a player. No damage -- Kill (25) is there for that. */
function HandleSlap(AOCRConPacket Packet)
{
	local QWord PlayerId;
	local Controller PC;    // Controller-level: a slap only needs a Pawn.
	local int Power;

	PlayerId = Packet.GetGUID();
	Power    = Packet.GetInt();

	PC = GetControllerFromGUID(PlayerId);
	if (PC == none)
		return;

	if (PC.Pawn == none)
	{
		AdminModDWAudit("SLAP_FAILED", DescribeController(PC) @ "- not alive");
		return;
	}

	Power = Clamp(Power, 50, 2000);
	class'AdminModDWAdminActions'.static.Slap(PC.Pawn, Power);
	AdminModDWAudit("SLAP", DescribeController(PC) @ "power" @ Power);
}

/**
 * 51: freeze or release a player, via TB's tutorial input blocking
 * (ScriptToggleInput -> ClientScriptToggleInput, already a reliable client function).
 *
 * NOT anti-cheat. TB's own comment there: "This isn't a safe way of preventing a player
 * from performing some action. It's intended for SP/Tutorials." Enforcement is
 * client-side, so a modified client ignores it. Talk is left unblocked on purpose.
 */
function AdminModDWSetFrozen(AOCPlayerController PC, bool bFrozen)
{
	// bEnable == true means ALLOWED (ClientScriptToggleInput stores the negation), so
	// freezing passes false.
	local bool bAllow;
	bAllow = !bFrozen;

	PC.ScriptToggleInput(EINBLOCK_MoveForward,   bAllow);
	PC.ScriptToggleInput(EINBLOCK_MoveBackward,  bAllow);
	PC.ScriptToggleInput(EINBLOCK_MoveLeft,      bAllow);
	PC.ScriptToggleInput(EINBLOCK_MoveRight,     bAllow);
	PC.ScriptToggleInput(EINBLOCK_Jump,          bAllow);
	PC.ScriptToggleInput(EINBLOCK_Crouch,        bAllow);
	PC.ScriptToggleInput(EINBLOCK_Sprint,        bAllow);
	PC.ScriptToggleInput(EINBLOCK_Dodge,         bAllow);
	PC.ScriptToggleInput(EINBLOCK_AttackSlash,   bAllow);
	PC.ScriptToggleInput(EINBLOCK_AttackStab,    bAllow);
	PC.ScriptToggleInput(EINBLOCK_AttackOverhead,bAllow);
	PC.ScriptToggleInput(EINBLOCK_AttackShove,   bAllow);
	PC.ScriptToggleInput(EINBLOCK_AttackSprint,  bAllow);
	PC.ScriptToggleInput(EINBLOCK_Block,         bAllow);
	PC.ScriptToggleInput(EINBLOCK_Feint,         bAllow);
}

function HandleSetFrozen(AOCRConPacket Packet)
{
	local QWord PlayerId;
	local AOCPlayerController PC;
	local bool bFrozen;

	PlayerId = Packet.GetGUID();
	bFrozen  = (Packet.GetInt() != 0);

	PC = GetPlayerControllerFromGUID(PlayerId);
	if (PC == none)
		return;

	AdminModDWSetFrozen(PC, bFrozen);
	AdminModDWAudit(bFrozen ? "FREEZE" : "UNFREEZE",
		DescribeController(PC) @ "- client-side block, not cheat-proof");
}

/**
 * 52: change class, keeping the team.
 *
 * DW delta: index 0-5 into AOCPawn.PlayerClasses, which in Deadliest Warrior is
 * EAOCClass order -- 0 Samurai, 1 Spartan, 2 Viking, 3 Knight, 4 Ninja, 5 Pirate. The
 * base game's five Agatha/Mason classes and its GRI.FamilyInfos table do not exist here.
 *
 * bForceSwitch=true so SetNewClass picks a loadout legal for the new class. Vanilla applies
 * on next spawn; immediate=1 kills the pawn so it lands now -- a flag, not the default,
 * because killing someone mid-fight to change their class is a rude surprise.
 */
function HandleSetClass(AOCRConPacket Packet)
{
	local QWord PlayerId;
	local AOCPlayerController PC;
	local class<AOCFamilyInfo> NewFamily;
	local AOCTeamInfo MyTeam;
	local int ClassIndex, bImmediate;

	PlayerId   = Packet.GetGUID();
	ClassIndex = Packet.GetInt();
	bImmediate = Packet.GetInt();

	PC = GetPlayerControllerFromGUID(PlayerId);
	if (PC == none)
		return;

	if (PC.PlayerReplicationInfo == none || PC.PlayerReplicationInfo.Team == none)
	{
		AdminModDWAudit("SET_CLASS_FAILED", DescribeController(PC) @ "- not on a team yet");
		return;
	}

	if (ClassIndex < 0 || ClassIndex >= ECLASS_Random)
	{
		AdminModDWAudit("SET_CLASS_FAILED", DescribeController(PC) @ "- bad class index" @ ClassIndex
			@ "(0 Samurai, 1 Spartan, 2 Viking, 3 Knight, 4 Ninja, 5 Pirate)");
		return;
	}

	MyTeam = AOCTeamInfo(PC.PlayerReplicationInfo.Team);
	if (MyTeam != none && !Bool(MyTeam.AllowedClasses[ClassIndex]))
	{
		AdminModDWAudit("SET_CLASS_FAILED", DescribeController(PC)
			@ "- class" @ ClassIndex @ "is not allowed on this team on this map");
		return;
	}

	NewFamily = class'AOCPawn'.default.PlayerClasses[EAOCClass(ClassIndex)];
	if (NewFamily == none)
	{
		AdminModDWAudit("SET_CLASS_FAILED", DescribeController(PC)
			@ "- PlayerClasses[" $ ClassIndex $ "] is none");
		return;
	}

	PC.SetNewClass(NewFamily, PC.PlayerReplicationInfo.Team, false, true);

	if (bImmediate != 0 && PC.Pawn != none)
		PC.Pawn.Died(none, class'AOCDmgType_Swing', vect(0, 0, 0));

	AdminModDWAudit("SET_CLASS", DescribeController(PC) @ "->" @ string(NewFamily.Name)
		@ (bImmediate != 0 ? "(respawned now)" : "(applies on next spawn)"));
}

/**
 * 53: list the weapons this class may take, as indices into AOCFamilyInfo.New*Weapons.
 * Opcode 56 sets by the same index, so no class paths on the wire and no strings to trust.
 *
 * DW delta: CurrentFamilyInfo is a class reference here, so the weapon lists are read off
 * .default rather than off an instance. The lists themselves are the same struct.
 */
function HandleLoadoutRequest(AOCRConPacket Packet)
{
	local QWord PlayerId;
	local AOCPlayerController PC;
	local AOCRConPacket Reply;
	local class<AOCFamilyInfo> Fam;
	local int i;

	PlayerId = Packet.GetGUID();
	PC = GetPlayerControllerFromGUID(PlayerId);
	if (PC == none || PC.CurrentFamilyInfo == none)
		return;

	Fam = PC.CurrentFamilyInfo;

	for (i = 0; i < Fam.default.NewPrimaryWeapons.Length; i++)
		SendLoadoutOption(PlayerId, SLOT_PRIMARY, i, Fam.default.NewPrimaryWeapons[i].CWeapon);
	for (i = 0; i < Fam.default.NewSecondaryWeapons.Length; i++)
		SendLoadoutOption(PlayerId, SLOT_SECONDARY, i, Fam.default.NewSecondaryWeapons[i].CWeapon);
	for (i = 0; i < Fam.default.NewTertiaryWeapons.Length; i++)
		SendLoadoutOption(PlayerId, SLOT_TERTIARY, i, Fam.default.NewTertiaryWeapons[i].CWeapon);

	Reply = new class'AOCRConPacket';
	Reply.SetMessageType(RCONX_LOADOUT_END);
	Reply.AddQWord(PlayerId);
	Reply.AddInt(Fam.default.NewPrimaryWeapons.Length);
	Reply.AddInt(Fam.default.NewSecondaryWeapons.Length);
	Reply.AddInt(Fam.default.NewTertiaryWeapons.Length);
	SendPacket(Reply);
}

function SendLoadoutOption(QWord PlayerId, int Slot, int Index, class<AOCWeapon> W)
{
	local AOCRConPacket Reply;

	Reply = new class'AOCRConPacket';
	Reply.SetMessageType(RCONX_LOADOUT_OPTION);
	Reply.AddQWord(PlayerId);
	Reply.AddInt(Slot);
	Reply.AddInt(Index);
	Reply.AddString((W != none) ? string(W.Name) : "(none)");
	SendPacket(Reply);
}

/**
 * 56: set loadout by index; -1 leaves a slot alone. Server-side only on purpose -- this is
 * what they spawn with. Their own class menu will not show it until it next refreshes.
 */
function HandleSetLoadout(AOCRConPacket Packet)
{
	local QWord PlayerId;
	local AOCPlayerController PC;
	local class<AOCFamilyInfo> Fam;
	local class<AOCWeapon> Prim, Sec, Tert;
	local int iPrim, iSec, iTert;

	PlayerId = Packet.GetGUID();
	iPrim    = Packet.GetInt();
	iSec     = Packet.GetInt();
	iTert    = Packet.GetInt();

	PC = GetPlayerControllerFromGUID(PlayerId);
	if (PC == none || PC.CurrentFamilyInfo == none)
		return;

	Fam  = PC.CurrentFamilyInfo;
	Prim = PC.PrimaryWeapon;
	Sec  = PC.SecondaryWeapon;
	Tert = PC.TertiaryWeapon;

	if (iPrim >= 0 && iPrim < Fam.default.NewPrimaryWeapons.Length)
		Prim = Fam.default.NewPrimaryWeapons[iPrim].CWeapon;
	if (iSec >= 0 && iSec < Fam.default.NewSecondaryWeapons.Length)
		Sec = Fam.default.NewSecondaryWeapons[iSec].CWeapon;
	if (iTert >= 0 && iTert < Fam.default.NewTertiaryWeapons.Length)
		Tert = Fam.default.NewTertiaryWeapons[iTert].CWeapon;

	// AltPrimaryWeapon is carried through untouched -- it is not part of the choice lists
	// and clobbering it would drop the alternate mode of whatever they are holding.
	PC.SetWeapons(Prim, PC.AltPrimaryWeapon, Sec, Tert);

	AdminModDWAudit("SET_LOADOUT", DescribeController(PC) @ "->" @ Prim @ "/" @ Sec @ "/" @ Tert
		@ "(applies on next spawn)");
}

/**
 * 57: one snapshot of where everyone is.
 *
 * Reads Pawn.Location, not the replicated AOCPRI.PawnLocation -- we already run
 * server-side. PawnLocation is the fallback for a dead pawn. Yaw in degrees so the client
 * need not know UE3 rotator units.
 */
function SendPlayerPositions()
{
	local AOCRConPacket Reply;
	local PlayerReplicationInfo PRI;
	local AOCPRI APRI;
	local Controller C;
	local Vector Loc;
	local int Count, Yaw, bAlive;

	// Bail out through the terminator, never by returning. The client swaps in a frame on
	// PLAYER_POS_END; a bare return leaves it waiting and the map simply never updates,
	// which is indistinguishable from the opcode not being implemented at all.
	if (WorldInfo.GRI == none)
	{
		AdminModDWAudit("PLAYER_POS_FAILED", "no GameReplicationInfo yet");
		Reply = new class'AOCRConPacket';
		Reply.SetMessageType(RCONX_PLAYER_POS_END);
		Reply.AddInt(0);
		SendPacket(Reply);
		return;
	}

	foreach WorldInfo.GRI.PRIArray(PRI)
	{
		if (PRI == none || PRI.bOnlySpectator)
			continue;

		EnsureUniqueId(PRI);

		APRI = AOCPRI(PRI);
		C = Controller(PRI.Owner);

		bAlive = 0;
		Yaw = 0;

		if (C != none && C.Pawn != none)
		{
			Loc = C.Pawn.Location;
			Yaw = (C.Pawn.Rotation.Yaw & 65535) * 360 / 65536;
			bAlive = 1;
		}
		else if (APRI != none)
		{
			Loc = APRI.PawnLocation;   // last known, replicated from AOCPawn
		}
		else
		{
			continue;
		}

		Reply = new class'AOCRConPacket';
		Reply.SetMessageType(RCONX_PLAYER_POS);
		Reply.AddQWord(PRI.UniqueId.Uid);
		Reply.AddString(PRI.PlayerName);
		Reply.AddInt((PRI.Team != none) ? PRI.Team.TeamIndex : -1);
		Reply.AddInt(int(Loc.X));
		Reply.AddInt(int(Loc.Y));
		Reply.AddInt(int(Loc.Z));
		Reply.AddInt(Yaw);
		Reply.AddInt(bAlive);
		Reply.AddInt((APRI != none) ? APRI.CurrentHealth : 0);
		SendPacket(Reply);
		Count++;
	}

	Reply = new class'AOCRConPacket';
	Reply.SetMessageType(RCONX_PLAYER_POS_END);
	Reply.AddInt(Count);
	SendPacket(Reply);
}

/* ============================ tournament mode =============================== */

/**
 * 49: turn tournament mode on or off, and optionally set the ready threshold.
 *
 * DW delta, rebuilt rather than ported. Deadliest Warrior has no tournament mode: no
 * bTournamentMode, no TournamentTeamReadyThreshold, no ready fields on AOCGRI or AOCPRI,
 * and no AdminTournamentMode exec. What it has is bWaitForTeams plus
 * AOCPlayerController.bReady, gated in AOCGame.ShouldCountDown, which starts the round as
 * soon as ONE player per team is ready.
 *
 * So tournament mode here is: force bWaitForTeams on, and have
 * AdminModDWGame.ShouldCountDown require AdminModDWReadyThreshold of each team instead of
 * one player. Unlike the base game's version this is NOT one-shot per round -- it stays on
 * until an admin turns it off, and gates every round on the map.
 *
 * The InitGame-style side effects mirror what the base game grants in tournament mode.
 * They are not reverted on disable, because we cannot know what the server had before --
 * except bWaitForTeams, which is saved and restored since we are the ones forcing it.
 */
function HandleSetTournament(AOCRConPacket Packet)
{
	local AOCGame Game;
	local AdminModDWRCon Shared;
	local int bEnabled, ThresholdPercent;

	bEnabled         = Packet.GetInt();
	ThresholdPercent = Packet.GetInt();

	Game = AOCGame(WorldInfo.Game);
	if (Game == none || Game.GameReplicationInfo == none)
	{
		AdminModDWAudit("TOURNAMENT_FAILED", (Game == none)
			? "the game is not an AOCGame"
			: "no GameReplicationInfo yet");
		return;
	}

	Shared = AdminModDWShared();

	if (ThresholdPercent > 0)
		Shared.AdminModDWReadyThreshold = FClamp(float(ThresholdPercent) / 100.0, 0.01, 1.0);

	// Either direction starts from a clean slate: leaving stale flags behind would let a
	// round start on readiness collected under different rules.
	AdminModDWClearReady();

	Shared.bAdminModDWTournamentMode = (bEnabled != 0);

	if (Shared.bAdminModDWTournamentMode)
	{
		Game.bDisableAutoBalance = true;
		AOCGRI(Game.GameReplicationInfo).bBalanceTeams = false;
		Game.bUseMaxPingLimit = false;
		// Without bAdminCanPause an in-game admin's console pause is refused by
		// AllowPausing even in tournament mode.
		Game.bAdminCanPause = true;
		Game.bAnyUserCanGetSteamID = true;

		AdminModDWAnnounceReady("Tournament mode ON -- type !ready when you are set."
			@ "The round will not start until"
			@ int(Shared.AdminModDWReadyThreshold * 100) $ "% of each team is ready.", "#4CC964");
	}
	else
	{
		AdminModDWAnnounceReady("Tournament mode OFF.", "#D1A04A");
	}

	Game.GameReplicationInfo.bForceNetUpdate = true;

	AdminModDWAudit(Shared.bAdminModDWTournamentMode ? "TOURNAMENT_ON" : "TOURNAMENT_OFF",
		"ready threshold" @ int(Shared.AdminModDWReadyThreshold * 100) $ "%"
		@ "- ready flags cleared; gates every round until turned off, runtime-only");
}

/**
 * 50: force everyone ready, or clear every ready flag.
 *
 * Acts on the mod's own ready list, not on AOCPlayerController.bReady -- see the note on
 * AdminModDWReadyIds for why that flag is unusable as a tournament gate. It also means
 * nothing needs pushing to clients: readiness is announced in chat, so there is no replicated
 * state to keep in step.
 */
function HandleReadyAll(AOCRConPacket Packet)
{
	local AOCGame Game;
	local AOCPlayerController PC;
	local int bReady, Count;

	bReady = Packet.GetInt();

	Game = AOCGame(WorldInfo.Game);
	if (Game == none)
		return;

	if (bReady != 0)
	{
		foreach WorldInfo.AllControllers(class'AOCPlayerController', PC)
		{
			if (PC.IsVoluntarySpectator() || PC.PlayerReplicationInfo == none
				|| PC.PlayerReplicationInfo.bOnlySpectator)
				continue;

			if (AdminModDWSetPlayerReady(PC.PlayerReplicationInfo, true))
				Count++;
		}

		// Latched, so a player joining mid-countdown cannot pull the round back into
		// waiting after an admin has said go. Someone typing !unready drops it again.
		AdminModDWShared().bAdminModDWForcedReady = true;

		AdminModDWAnnounceReady("An admin marked all players ready.", "#4CC964");
		AdminModDWAudit("READY_ALL", "forced" @ Count @ "player(s) ready");
		return;
	}

	Count = AdminModDWShared().AdminModDWReadyIds.Length;
	AdminModDWClearReady();

	AdminModDWAnnounceReady("An admin cleared all ready flags -- type !ready again.", "#D1A04A");
	AdminModDWAudit("UNREADY_ALL", "cleared" @ Count @ "player(s) and the admin ready override");
}

/* ============================ match control ================================= */

/**
 * 43: pause / unpause. Borrows a controller to own the pause -- an admin if one is
 * connected, otherwise the first.
 *
 * Calls AOCGame.SetPause, not PlayerController.SetPause: only AOCGame's sets AOCGRI.Speed
 * and calls NotifyPaused, and the borrowed controller is not an admin.
 *
 * bPauseable is forced on around the call and restored after. AOCGame inherits
 * bPauseable=False, so AllowPausing falls through to bAdminCanPause && IsAdmin -- false in
 * the ini, and the borrowed controller is no admin. Without the flip SetPause just returns
 * false.
 */
function HandleSetPause(AOCRConPacket Packet)
{
	local bool bPause;
	local AOCPlayerController PC, Chosen;
	local AOCGame Game;

	bPause = (Packet.GetInt() != 0);

	Game = AOCGame(WorldInfo.Game);
	if (Game == none)
		return;

	foreach WorldInfo.AllControllers(class'AOCPlayerController', PC)
	{
		if (Chosen == none)
			Chosen = PC;

		if (PC.PlayerReplicationInfo != none && PC.PlayerReplicationInfo.bAdmin)
		{
			Chosen = PC;
			break;
		}
	}

	if (Chosen == none)
	{
		AdminModDWAudit("SET_PAUSE_FAILED", "nobody connected to own the pause");
		return;
	}

	if (bPause)
	{
		if (WorldInfo.Pauser != none)
			return;

		Chosen.bFire = 0;

		if (!AdminModDWShared().bAdminModDWPauseForced)
		{
			AdminModDWShared().bAdminModDWPauseableWas = Game.bPauseable;
			AdminModDWShared().bAdminModDWPauseForced = true;
		}
		Game.bPauseable = true;

		if (!Game.SetPause(Chosen))
		{
			Game.bPauseable = AdminModDWShared().bAdminModDWPauseableWas;
			AdminModDWShared().bAdminModDWPauseForced = false;
			AdminModDWAudit("SET_PAUSE_FAILED", "the game refused the pause");
			return;
		}
		Chosen.PauseRumbleForAllPlayers();
	}
	else
	{
		// While ClearPause runs: AllowPausing() false takes the wipe-the-list branch, which
		// also unpauses, but keep the flag on so the normal delegate path is used instead.
		Game.ClearPause();
		Chosen.PauseRumbleForAllPlayers(false);

		if (AdminModDWShared().bAdminModDWPauseForced)
		{
			Game.bPauseable = AdminModDWShared().bAdminModDWPauseableWas;
			AdminModDWShared().bAdminModDWPauseForced = false;
		}
	}

	// AOCGame.SetPause already broadcasts its own "paused the game" system message (naming
	// the borrowed controller), but ClearPause announces nothing -- so only unpause needs one.
	if (!bPause)
		Game.BroadcastMessage(none, "An admin unpaused the match.", EFAC_ALL, true, true, "#4CC964");

	AdminModDWAudit("SET_PAUSE", (bPause ? "paused" : "unpaused") @ "via" @ DescribeController(Chosen));
}

/**
 * 44: end the match now, awarding it to a team.
 *
 * EndGame wants a winning PRI rather than a team index, so the team's top scorer
 * stands in for it -- that is what AOCGame.GetHighestScoreFromTeam is for. A team with
 * nobody on it ends the match with no winner rather than failing silently.
 */
function HandleEndMatch(AOCRConPacket Packet)
{
	local int WinningTeam;
	local string Reason;
	local PlayerReplicationInfo WinnerPRI;
	local AOCGame Game;

	WinningTeam = Packet.GetInt();
	Reason      = Packet.GetString();

	Game = AOCGame(WorldInfo.Game);
	if (Game == none)
		return;

	if (WinningTeam >= 0)
		WinnerPRI = Game.GetHighestScoreFromTeam(WinningTeam);

	// No team named, or nobody left on it. Fall back to whoever the game itself would crown --
	// the same call AOCGame.ManuallyEndGame makes. AOCFFA and AOCDuel read Winner.PlayerName
	// without a null check, so handing them none costs the end screen its name.
	if (WinnerPRI == none)
		WinnerPRI = Game.GetHighestScoreFromTeam(Game.GetWinningTeam());

	// EndGame's Reason is a match-end CONDITION string, not anything a player ever sees --
	// which is why the reason never reached chat. Announce it separately first, while there is
	// still a round to announce it into.
	if (Reason != "")
		Game.BroadcastMessage(none, "Match ended by admin:" @ Reason, EFAC_ALL, true, true, "#D1A04A");

	AdminModDWAudit("END_MATCH", "team" @ WinningTeam @ "|" @ Reason);

	// "TimeLimit" is not decoration, it is the only value that works in every mode.
	// AOCFFA.EndGame runs its body only for Reason ~= "TimeLimit" (Medieval Warfare also
	// accepts "Admin action"; Deadliest Warrior's copy does not), and AOCDuel.EndGame gates its
	// main branch on "TimeLimit" alone. Anything else is a SILENT no-op in free-for-all -- the
	// packet is handled, the audit fires, and the match simply never ends. Every base AOCGame
	// mode passes Reason straight to EndLogging and ignores it, so nothing is lost by it.
	Game.EndGame(WinnerPRI, "TimeLimit");
}

/**
 * 45: toggle auto team balance.
 *
 * DW delta: AOCGRI.bBalanceTeams is only what the HUD draws. The gate that actually stops
 * a swap is AOCGame.bDisableAutoBalance, first line of PerformDeathBasedAB, so both are
 * set here.
 */
function HandleSetAutoBalance(AOCRConPacket Packet)
{
	local bool bEnable;
	local AOCGame Game;

	bEnable = (Packet.GetInt() != 0);

	Game = AOCGame(WorldInfo.Game);
	if (Game == none || AOCGRI(WorldInfo.GRI) == none)
		return;

	Game.bDisableAutoBalance = !bEnable;
	AOCGRI(WorldInfo.GRI).bBalanceTeams = bEnable;
	WorldInfo.GRI.bForceNetUpdate = true;

	AdminModDWAudit("SET_AUTOBALANCE", bEnable ? "on" : "off");
}

/**
 * 46: game speed as an integer percent (no float on the wire); 100 is normal.
 * AOCGame.SetGameSpeed rather than a slomo console command: it calls NotifySpeedChanged and
 * republishes AOCGRI.Speed, which the bare command does not. Clamped 10-400 -- zero stops
 * the match with no way to type the command that would restore it.
 */
function HandleSetGameSpeed(AOCRConPacket Packet)
{
	local int SpeedPercent;
	local float NewSpeed;

	SpeedPercent = Packet.GetInt();
	SpeedPercent = Clamp(SpeedPercent, 10, 400);
	NewSpeed = float(SpeedPercent) / 100.0;

	if (WorldInfo.Game == none)
		return;

	AdminModDWAudit("SET_GAME_SPEED", SpeedPercent $ "%");
	WorldInfo.Game.SetGameSpeed(NewSpeed);
}

/** 47: restart the current match. */
function HandleRestartMatch()
{
	if (WorldInfo.Game == none)
		return;

	// NOT RestartGame(): with bChangeLevels set it calls GetNextMap() and travels there, so
	// it cycles the rotation instead of restarting. "?restart" is the URL option the
	// engine's own restart path uses.
	AdminModDWAudit("RESTART_MATCH", "reloading the current map");
	WorldInfo.ServerTravel("?restart", false);
}

DefaultProperties
{
	// AdminModDWBlockedConsoleCommands is deliberately NOT seeded here: it is a config
	// array, and the compiler refuses the import ("property is config"), which left the
	// block list empty at runtime. The defaults live in DefaultAdminModDW.ini instead.

	// Tournament ready gate: everyone on each team, until an admin lowers it with
	// opcode 49. Not config -- tournament mode itself is runtime-only.
	AdminModDWReadyThreshold=1.0
}
