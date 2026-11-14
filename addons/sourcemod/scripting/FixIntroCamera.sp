#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

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

// Per client: < 0 waiting for the first real usercmd, 0 nothing to do,
// > 0 game time until which in-flight usercmds get the intro angles.
float g_fFixEnd[MAXPLAYERS + 1];
float g_vIntroAngles[MAXPLAYERS + 1][3];

public void OnPluginStart()
{
	if (GetEngineVersion() != Engine_CSS)
		SetFailState("This plugin only supports Counter-Strike: Source");
}

public void OnClientPutInServer(int client)
{
	// A client entering the game always starts on the intro camera (STATE_WELCOME).
	g_fFixEnd[client] = IsFakeClient(client) ? 0.0 : -1.0;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	float fFixEnd = g_fFixEnd[client];
	if (fFixEnd == 0.0)
		return Plugin_Continue;

	if (fFixEnd < 0.0)
	{
		// cmdnum 0: a null command run by the server while the client is loading.
		if (cmdnum <= 0)
			return Plugin_Continue;

		// The eye angles are still the ones MoveToNextIntroCamera() set.
		GetClientEyeAngles(client, g_vIntroAngles[client]);
		if (SameAngles(angles, g_vIntroAngles[client]))
		{
			g_fFixEnd[client] = 0.0;
			return Plugin_Continue;
		}

		// Teleport calls SnapEyeAngles(): this time the angles reach the client.
		TeleportEntity(client, NULL_VECTOR, g_vIntroAngles[client], NULL_VECTOR);
		g_fFixEnd[client] = GetGameTime() + INTRO_FIX_WINDOW;
	}
	else if (GetGameTime() > fFixEnd || SameAngles(angles, g_vIntroAngles[client]))
	{
		// The client applied the angles, or the window is over.
		g_fFixEnd[client] = 0.0;
		return Plugin_Continue;
	}

	// Commands already in flight still carry the old view: replace their angles.
	angles = g_vIntroAngles[client];
	return Plugin_Changed;
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
