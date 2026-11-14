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
	version = "1.0.0",
	url = "https://github.com/srcdslab/sm-plugin-FixIntroCamera"
};

// How long we keep forcing the intro angles while the client applies them.
#define INTRO_FIX_WINDOW 1.0

DynamicHook g_hPlayerRunCmd;
int g_iOffCmdNumber;
int g_iOffViewAngles;

// Per client: < 0 waiting for the first real usercmd, 0 done,
// > 0 game time until which in-flight usercmds get the intro angles.
float g_fFixEnd[MAXPLAYERS + 1];
float g_vIntroAngles[MAXPLAYERS + 1][3];
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

	float vAngles[3];
	if (fFixEnd < 0.0)
	{
		// command_number 0: a null command run by the server while the client is loading.
		if (hParams.GetObjectVar(1, g_iOffCmdNumber, ObjectValueType_Int) <= 0)
			return MRES_Ignored;

		// The eye angles are still the ones MoveToNextIntroCamera() set.
		hParams.GetObjectVarVector(1, g_iOffViewAngles, ObjectValueType_Vector, vAngles);
		GetClientEyeAngles(client, g_vIntroAngles[client]);
		if (SameAngles(vAngles, g_vIntroAngles[client]))
		{
			Done(client);
			return MRES_Ignored;
		}

		// Teleport calls SnapEyeAngles(): this time the angles reach the client.
		TeleportEntity(client, NULL_VECTOR, g_vIntroAngles[client], NULL_VECTOR);
		g_fFixEnd[client] = GetGameTime() + INTRO_FIX_WINDOW;
	}
	else
	{
		hParams.GetObjectVarVector(1, g_iOffViewAngles, ObjectValueType_Vector, vAngles);
		if (GetGameTime() > fFixEnd || SameAngles(vAngles, g_vIntroAngles[client]))
		{
			// The client applied the angles, or the window is over.
			Done(client);
			return MRES_Ignored;
		}
	}

	// Commands already in flight still carry the old view: replace their angles.
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
	return FloatAbs(AngleDiff(a[0], b[0])) < 1.0 && FloatAbs(AngleDiff(a[1], b[1])) < 1.0;
}

float AngleDiff(float a, float b)
{
	float diff = a - b;
	while (diff > 180.0)
		diff -= 360.0;
	while (diff < -180.0)
		diff += 360.0;
	return diff;
}
