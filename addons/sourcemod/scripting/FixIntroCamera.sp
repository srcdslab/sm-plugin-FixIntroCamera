#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <dhooks>

/*
 * CS:S intro camera: the first point_viewcontrol with a target, shown behind the
 * MOTD while a player joins.
 *
 * CCSPlayer::MoveToNextIntroCamera() aims the player at the camera target from
 * ClientActive with SnapEyeAngles(), which sets pl.fixangle. On a dedicated server
 * the client is still loading at that point and sends no usercmds, so the server
 * runs CBasePlayer::RunNullCommand() every tick, and that clears pl.fixangle before
 * the angles are ever sent. The first real usercmd then carries the client's
 * default view (0 0 0) and overwrites the camera angles, until the game snaps the
 * view again 6 seconds later.
 *
 * Fix: on the first real usercmd, while the player is still on the intro camera,
 * send the camera angles again and keep them until the client has applied them.
 * The player is only hooked from ClientPutInServer until then, so nothing runs
 * per usercmd once the camera is fixed.
 */

public Plugin myinfo =
{
	name = "FixIntroCamera",
	author = "Rushaway",
	description = "Fixes the CS:S intro camera facing the wrong way for a few seconds after joining",
	version = "1.0.1",
	url = "https://github.com/srcdslab/sm-plugin-FixIntroCamera"
};

// How long (real time) we keep forcing the intro angles while the client applies
// them. The client took 0.97 s on ze_umbra_v1_4 (2026-11-15), hence 2 s. Not game
// time: in PlayerRunCommand it follows the player's tick base, which jumped by 240
// ticks (3.6 s) while a client loaded a big map.
#define INTRO_FIX_WINDOW 2.0

DynamicHook g_hPlayerRunCmd;
int g_iOffCmdNumber;
int g_iOffViewAngles;

// Per client: < 0 waiting for the first real usercmd, 0 done,
// > 0 engine time until which in-flight usercmds get the intro angles.
float g_fFixEnd[MAXPLAYERS + 1];
float g_vIntroAngles[MAXPLAYERS + 1][3];
bool g_bHaveAngles[MAXPLAYERS + 1];
int g_iLastCmd[MAXPLAYERS + 1];
int g_iHookId[MAXPLAYERS + 1] = {INVALID_HOOK_ID, ...};

public void OnPluginStart()
{
	if (GetEngineVersion() != Engine_CSS)
		SetFailState("This plugin only supports Counter-Strike: Source");

	// CBasePlayer::PlayerRunCommand(CUserCmd *ucmd, IMoveHelper *moveHelper)
	GameData hSDKTools = new GameData("sdktools.games");
	if (hSDKTools == null)
		SetFailState("Couldn't load sdktools game config!");

	int iOffRunCmd = hSDKTools.GetOffset("PlayerRunCmd");
	delete hSDKTools;
	if (iOffRunCmd == -1)
		SetFailState("Failed to find PlayerRunCmd offset");

	GameData hConfig = new GameData("FixIntroCamera.games");
	if (hConfig == null)
		SetFailState("Couldn't load FixIntroCamera.games game config!");

	g_iOffCmdNumber = hConfig.GetOffset("CUserCmd::command_number");
	g_iOffViewAngles = hConfig.GetOffset("CUserCmd::viewangles");
	delete hConfig;
	if (g_iOffCmdNumber == -1 || g_iOffViewAngles == -1)
		SetFailState("Failed to find CUserCmd offsets");

	g_hPlayerRunCmd = new DynamicHook(iOffRunCmd, HookType_Entity, ReturnType_Void, ThisPointer_CBaseEntity);
	g_hPlayerRunCmd.AddParam(HookParamType_ObjectPtr);
	g_hPlayerRunCmd.AddParam(HookParamType_ObjectPtr);
}

public void OnClientPutInServer(int client)
{
	g_fFixEnd[client] = 0.0;
	g_iLastCmd[client] = 0;
	g_bHaveAngles[client] = false;
	g_iHookId[client] = INVALID_HOOK_ID;
	if (IsFakeClient(client))
		return;

	// A client entering the game always starts on the intro camera (STATE_WELCOME).
	g_iHookId[client] = g_hPlayerRunCmd.HookEntity(Hook_Pre, client, Hook_PlayerRunCmd);
	if (g_iHookId[client] != INVALID_HOOK_ID)
		g_fFixEnd[client] = -1.0;
}

public void OnClientDisconnect(int client)
{
	Unhook(client);
}

public MRESReturn Hook_PlayerRunCmd(int client, DHookParam hParams)
{
	float fFixEnd = g_fFixEnd[client];
	if (fFixEnd == 0.0)
		return MRES_Ignored;

	// First call, from the first null command or usercmd after ClientActive: the eye
	// angles are still the ones MoveToNextIntroCamera() set. Read them now, before any
	// usercmd goes through PlayerRunCommand and changes them.
	// VectorAngles() returns them in [0, 360), so a camera looking up has a pitch like
	// 352.9. Keep them as a client sends them ([-180, 180]): anticheats clamp the
	// usercmd pitch to 89 (Lilac turned 352.9 into 89 on ze_rooftop_runaway1_v4, view
	// straight down for 5 s, 2026-11-15).
	if (!g_bHaveAngles[client])
	{
		GetClientEyeAngles(client, g_vIntroAngles[client]);
		for (int i = 0; i < 3; i++)
			g_vIntroAngles[client][i] = NormalizeAngle(g_vIntroAngles[client][i]);
		g_bHaveAngles[client] = true;
	}

	// command_number 0 is a null command, run every tick while the client is loading,
	// with the eye angles as viewangles. Give it the normalized angles, or Lilac
	// clamps the pitch and the eye angles become 89 (seen 2026-11-15).
	int iCmd = hParams.GetObjectVar(1, g_iOffCmdNumber, ObjectValueType_Int);
	if (iCmd == 0)
	{
		hParams.SetObjectVarVector(1, g_iOffViewAngles, ObjectValueType_Vector, g_vIntroAngles[client]);
		return MRES_Ignored;
	}

	// Only look at new usercmds: when no new usercmd arrived in time the server runs
	// the last one again, with the angles we already wrote into it (seen 2026-11-15).
	if (iCmd <= g_iLastCmd[client])
		return MRES_Ignored;

	g_iLastCmd[client] = iCmd;

	float vAngles[3];
	hParams.GetObjectVarVector(1, g_iOffViewAngles, ObjectValueType_Vector, vAngles);

	if (fFixEnd < 0.0)
	{
		// First real usercmd.
		if (SameAngles(vAngles, g_vIntroAngles[client]))
		{
			Done(client);
			return MRES_Ignored;
		}

		// Teleport calls SnapEyeAngles(): this time the angles reach the client.
		TeleportEntity(client, NULL_VECTOR, g_vIntroAngles[client], NULL_VECTOR);
		g_fFixEnd[client] = GetEngineTime() + INTRO_FIX_WINDOW;
	}
	else if (GetEngineTime() > fFixEnd || SameAngles(vAngles, g_vIntroAngles[client]))
	{
		// The client applied the angles, or the window is over.
		Done(client);
		return MRES_Ignored;
	}

	// Usercmds already in flight still carry the old view: replace their angles.
	// The CUserCmd is written in place, the call itself is unchanged.
	hParams.SetObjectVarVector(1, g_iOffViewAngles, ObjectValueType_Vector, g_vIntroAngles[client]);
	return MRES_Ignored;
}

void Done(int client)
{
	g_fFixEnd[client] = 0.0;
	// Don't remove a hook from inside its own callback.
	RequestFrame(Frame_Unhook, GetClientUserId(client));
}

void Frame_Unhook(int userid)
{
	int client = GetClientOfUserId(userid);
	if (client)
		Unhook(client);
}

void Unhook(int client)
{
	if (g_iHookId[client] == INVALID_HOOK_ID)
		return;

	DynamicHook.RemoveHook(g_iHookId[client]);
	g_iHookId[client] = INVALID_HOOK_ID;
}

bool SameAngles(const float a[3], const float b[3])
{
	return FloatAbs(NormalizeAngle(a[0] - b[0])) < 1.0 && FloatAbs(NormalizeAngle(a[1] - b[1])) < 1.0;
}

// Brings an angle into [-180, 180].
float NormalizeAngle(float a)
{
	while (a > 180.0)
		a -= 360.0;
	while (a < -180.0)
		a += 360.0;
	return a;
}
