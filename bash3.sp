// This is very much a work in progress. It does not work. I will publish the correct thresholds and weights when it is finished.

#include <sourcemod>
#include <sdktools>
#include <cstrike>
#include <sdkhooks>
#include <dbi>

#undef REQUIRE_EXTENSIONS
#include <dhooks>
#include <sendproxy>

#pragma newdecls required

#define BAN_LENGTH "0"
#define IDENTICAL_STRAFE_MIN 20

// Database configuration
#define MAX_RETRIES 5
#define INITIAL_RETRY_DELAY 5.0
#define MAX_RETRY_DELAY 300.0
#define MAX_BATCH_SIZE 100

ConVar g_cvDatabaseConfigName;
ConVar g_cvDatabaseRetryInterval;
char g_sDatabaseConfigName[64];
char g_sLogFile[PLATFORM_MAX_PATH];
int g_iReconnectAttempts = 0;
Handle g_hReconnectTimer = null;
Database g_hDatabase = null;

// added cvars for Event_PlayerJump thresholds
ConVar g_cvGainThreshold;
ConVar g_cvYawThreshold;
ConVar g_cvTimingThreshold;

// added cvars for CheckForIllegalTurning and CheckForIllegalMovement thresholds
ConVar g_cvIllegalTurnThreshold;
ConVar g_cvIllegalMoveThreshold;
ConVar g_cvConsistencyThreshold;
ConVar g_cvAlternationThreshold;

public Plugin myinfo =
{
	name = "[BASH] (Blacky's Anti-Strafehack)",
	author = "Blacky, edited by carnifex, and then edited by jessetooler",
	description = "Detects strafe hackers",
	version = "3.0",
	url = "https://youtube.com/@jejxkxk"
};

// checklag was confusing me until i figured out that it didn't actually exist
float g_fLag_LastCheckTime;
float g_fLastLagTime;
float g_fLagThreshold;
int g_iLaggedTicks;
int g_iMaxLaggedTicks;
ConVar g_hLagThreshold;
ConVar g_hMaxLaggedTicks;

#define LAG_HISTORY_SIZE 60
float g_fLagHistory[LAG_HISTORY_SIZE];
int g_iLagHistoryIndex;

// anti-cheat adjustment variables
float g_fNormalThresholdMultiplier = 1.0;
float g_fLagThresholdMultiplier = 1.5;
bool g_bSevereLatgSpike = false;

// Definitions
#define Button_Forward 0
#define Button_Back    1
#define Button_Left    2
#define Button_Right   3

#define BT_Move 0
#define BT_Key  1

#define Moving_Forward 0
#define Moving_Back    1
#define Moving_Left    2
#define Moving_Right   3

#define Turn_Left 0
#define Turn_Right 1

// Start/End Strafe Data
#define StrafeData_Button 0
#define StrafeData_TurnDirection 1
#define StrafeData_MoveDirection 2
#define StrafeData_Difference 3
#define StrafeData_Tick 4
#define StrafeData_IsTiming 5

// Key switch data
#define KeySwitchData_Button 0
#define KeySwitchData_Difference 1
#define KeySwitchData_IsTiming 2

// Detection reasons
#define DR_StartStrafe_LowDeviation (1 << 0) // < 1.0 very likely strafe hacks (Warn admins)
#define DR_StartStrafe_AlwaysPositive (1 << 1) // Might not be strafe hacking but a good indicator of someone trying to bypass anticheat (Warn admins)
#define DR_EndStrafe_LowDeviation (1 << 2) // < 1.0 very likely strafe hacks (Warn admins)
#define DR_EndStrafe_AlwaysPositive (1 << 3) // Might not be strafe hacking but a good indicator of someone trying to bypass anticheat (Warn admins)
#define DR_StartStrafeMatchesEndStrafe (1 << 4) // A way to catch an angle delay hack (Do nothing)
#define DR_KeySwitchesTooPerfect (1 << 5) // Could be movement config or anti ghosting keyboard (Warn admins)
#define DR_FailedManualAngleTest (1 << 6) // Almost definitely strafe hacking (Ban)
#define DR_ButtonsAndSideMoveDontMatch (1 << 7) // Could be caused by lag but can be made to detect strafe hacks perfectly (Ban/Warn based on severity)
#define DR_ImpossibleSideMove (1 << 8) // Could be +strafe or controller but most likely strafe hack (Warn admins/Stop player movements)
#define DR_FailedManualMOTDTest (1 << 9) // Almost definitely strafe hacking (Ban)
#define DR_AngleDelay (1 << 10) // Player freezes their angles for 1 or more ticks after they press a button until the angle changes again
#define DR_ImpossibleGains (1 << 11) // < 85% probably strafe hacks
#define DR_WiggleHack (1 << 12) // Almost definitely strafe hack. Check for IN_LEFT/IN_RIGHT
#define DR_TurningInfraction (1 << 13) // Client turns at impossible speeds

EngineVersion g_Engine;
int   g_iRealButtons[MAXPLAYERS + 1];
int   g_iButtons[MAXPLAYERS + 1][2];
int   g_iLastButtons[MAXPLAYERS + 1][2];
int   g_iLastPressTick[MAXPLAYERS + 1][4][2];
int   g_iLastPressTick_Recorded[MAXPLAYERS + 1][4][2];
int   g_iLastPressTick_Recorded_KS[MAXPLAYERS + 1][4][2];
int   g_iKeyPressesThisStrafe[MAXPLAYERS + 1][2];
int   g_iLastReleaseTick[MAXPLAYERS + 1][4][2];
int   g_iLastReleaseTick_Recorded[MAXPLAYERS + 1][4][2];
int   g_iLastReleaseTick_Recorded_KS[MAXPLAYERS + 1][4][2];
float g_fLastMove[MAXPLAYERS + 1][3];
int   g_iLastTurnDir[MAXPLAYERS + 1];
int   g_iLastTurnTick[MAXPLAYERS + 1];
int   g_iLastTurnTick_Recorded_StartStrafe[MAXPLAYERS + 1];
int   g_iLastTurnTick_Recorded_EndStrafe[MAXPLAYERS + 1];
int   g_iLastStopTurnTick[MAXPLAYERS + 1];
bool  g_bIsTurning[MAXPLAYERS + 1];
int   g_iReleaseTickAtLastEndStrafe[MAXPLAYERS + 1][4];
float g_fLastAngles[MAXPLAYERS + 1][3];
int   g_InvalidButtonSidemoveCount[MAXPLAYERS + 1];
int   g_iCmdNum[MAXPLAYERS + 1];
float g_fLastPosition[MAXPLAYERS + 1][3];
int   g_iLastTeleportTick[MAXPLAYERS + 1];
float g_fAngleDifference[MAXPLAYERS + 1][2];
float g_fLastAngleDifference[MAXPLAYERS + 1][2];

// Gain calculation
int   g_strafeTick[MAXPLAYERS + 1];
float g_flRawGain[MAXPLAYERS + 1];
bool  g_bTouchesWall[MAXPLAYERS + 1];
int   g_iJump[MAXPLAYERS + 1];
int   g_iTicksOnGround[MAXPLAYERS + 1];
float g_iYawSpeed[MAXPLAYERS + 1];
int   g_iYawTickCount[MAXPLAYERS + 1];
int   g_iTimingTickCount[MAXPLAYERS + 1];
int   g_iStrafesDone[MAXPLAYERS + 1];
bool  g_bFirstSixJumps[MAXPLAYERS + 1];
#define BHOP_TIME 15

// Optimizer detection
bool g_bTouchesFuncRotating[MAXPLAYERS + 1];

// Mouse cvars
float g_mYaw[MAXPLAYERS + 1]; int g_mYawChangedCount[MAXPLAYERS + 1]; int g_mYawCheckedCount[MAXPLAYERS + 1];
bool  g_mFilter[MAXPLAYERS + 1]; int g_mFilterChangedCount[MAXPLAYERS + 1]; int g_mFilterCheckedCount[MAXPLAYERS + 1];
int   g_mCustomAccel[MAXPLAYERS + 1]; int g_mCustomAccelChangedCount[MAXPLAYERS + 1]; int g_mCustomAccelCheckedCount[MAXPLAYERS + 1];
float g_mCustomAccelMax[MAXPLAYERS + 1]; int g_mCustomAccelMaxChangedCount[MAXPLAYERS + 1]; int g_mCustomAccelMaxCheckedCount[MAXPLAYERS + 1];
float g_mCustomAccelScale[MAXPLAYERS + 1]; int g_mCustomAccelScaleChangedCount[MAXPLAYERS + 1]; int g_mCustomAccelScaleCheckedCount[MAXPLAYERS + 1];
float g_mCustomAccelExponent[MAXPLAYERS + 1]; int g_mCustomAccelExponentChangedCount[MAXPLAYERS + 1]; int g_mCustomAccelExponentCheckedCount[MAXPLAYERS + 1];
bool  g_mRawInput[MAXPLAYERS + 1]; int g_mRawInputChangedCount[MAXPLAYERS + 1]; int g_mRawInputCheckedCount[MAXPLAYERS + 1];
float g_Sensitivity[MAXPLAYERS + 1]; int g_SensitivityChangedCount[MAXPLAYERS + 1]; int g_SensitivityCheckedCount[MAXPLAYERS + 1];
float g_JoySensitivity[MAXPLAYERS + 1]; int g_JoySensitivityChangedCount[MAXPLAYERS + 1]; int g_JoySensitivityCheckedCount[MAXPLAYERS + 1];
float g_ZoomSensitivity[MAXPLAYERS + 1]; int g_ZoomSensitivityChangedCount[MAXPLAYERS + 1]; int g_ZoomSensitivityCheckedCount[MAXPLAYERS + 1];
bool  g_JoyStick[MAXPLAYERS + 1]; int g_JoyStickChangedCount[MAXPLAYERS + 1]; int g_JoyStickCheckedCount[MAXPLAYERS + 1];
// i giga optimized this but hopefully we can remove most if not all of these soon anyway

// Recorded data to analyze
#define MAX_FRAMES 50 
#define MAX_FRAMES_KEYSWITCH 50 
int   g_iStartStrafe_CurrentFrame[MAXPLAYERS + 1];
any   g_iStartStrafe_Stats[MAXPLAYERS + 1][7][MAX_FRAMES];
int   g_iStartStrafe_LastRecordedTick[MAXPLAYERS + 1];
int   g_iStartStrafe_LastTickDifference[MAXPLAYERS + 1];
bool  g_bStartStrafe_IsRecorded[MAXPLAYERS + 1][MAX_FRAMES];
int   g_iStartStrafe_IdenticalCount[MAXPLAYERS + 1];
int   g_iEndStrafe_CurrentFrame[MAXPLAYERS + 1];
any   g_iEndStrafe_Stats[MAXPLAYERS + 1][7][MAX_FRAMES];
int   g_iEndStrafe_LastRecordedTick[MAXPLAYERS + 1];
int   g_iEndStrafe_LastTickDifference[MAXPLAYERS + 1];
bool  g_bEndStrafe_IsRecorded[MAXPLAYERS + 1][MAX_FRAMES];
int   g_iEndStrafe_IdenticalCount[MAXPLAYERS + 1];
int   g_iKeySwitch_CurrentFrame[MAXPLAYERS + 1][2];
any   g_iKeySwitch_Stats[MAXPLAYERS + 1][3][2][MAX_FRAMES_KEYSWITCH];
bool  g_bKeySwitch_IsRecorded[MAXPLAYERS + 1][2][MAX_FRAMES_KEYSWITCH];
int   g_iKeySwitch_LastRecordedTick[MAXPLAYERS + 1][2];
bool  g_iIllegalTurn[MAXPLAYERS + 1][MAX_FRAMES];
int   g_iIllegalTurn_CurrentFrame[MAXPLAYERS + 1];
bool  g_iIllegalTurn_IsTiming[MAXPLAYERS + 1][MAX_FRAMES];
int   g_iLastIllegalReason[MAXPLAYERS + 1];
int   g_iIllegalSidemoveCount[MAXPLAYERS + 1];
int   g_iLastIllegalSidemoveCount[MAXPLAYERS + 1];
int   g_iLastInvalidButtonCount[MAXPLAYERS + 1];
int   g_iYawChangeCount[MAXPLAYERS + 1];

//bool  g_bTasLoaded;
bool  g_bCheckedYet[MAXPLAYERS + 1];
float g_MOTDTestAngles[MAXPLAYERS + 1][3];
bool  g_bMOTDTest[MAXPLAYERS + 1];
int   g_iTarget[MAXPLAYERS + 1];

// this is like 5600+ bytes xd 
enum struct fuck_sourcemod
{
	int accountid;

	int   g_iRealButtons;
	int   g_iButtons[2];
	int   g_iLastButtons[2];

	//int   g_iLastPressTick[4][2];
	int   g_iLastPressTick_0[2];
	int   g_iLastPressTick_1[2];
	int   g_iLastPressTick_2[2];
	int   g_iLastPressTick_3[2];

	//int   g_iLastPressTick_Recorded[4][2];
	int   g_iLastPressTick_Recorded_0[2];
	int   g_iLastPressTick_Recorded_1[2];
	int   g_iLastPressTick_Recorded_2[2];
	int   g_iLastPressTick_Recorded_3[2];

	//int   g_iLastPressTick_Recorded_KS[4][2];
	int   g_iLastPressTick_Recorded_KS_0[2];
	int   g_iLastPressTick_Recorded_KS_1[2];
	int   g_iLastPressTick_Recorded_KS_2[2];
	int   g_iLastPressTick_Recorded_KS_3[2];

	int   g_iKeyPressesThisStrafe[2];

	//int   g_iLastReleaseTick[4][2];
	int   g_iLastReleaseTick_0[2];
	int   g_iLastReleaseTick_1[2];
	int   g_iLastReleaseTick_2[2];
	int   g_iLastReleaseTick_3[2];

	//int   g_iLastReleaseTick_Recorded[4][2];
	int   g_iLastReleaseTick_Recorded_0[2];
	int   g_iLastReleaseTick_Recorded_1[2];
	int   g_iLastReleaseTick_Recorded_2[2];
	int   g_iLastReleaseTick_Recorded_3[2];

	//int   g_iLastReleaseTick_Recorded_KS[4][2];
	int   g_iLastReleaseTick_Recorded_KS_0[2];
	int   g_iLastReleaseTick_Recorded_KS_1[2];
	int   g_iLastReleaseTick_Recorded_KS_2[2];
	int   g_iLastReleaseTick_Recorded_KS_3[2];

	float g_fLastMove[3];
	int   g_iLastTurnDir;
	int   g_iLastTurnTick;
	int   g_iLastTurnTick_Recorded_StartStrafe;
	int   g_iLastTurnTick_Recorded_EndStrafe;
	int   g_iLastStopTurnTick;
	bool  g_bIsTurning;
	int   g_iReleaseTickAtLastEndStrafe[4];
	float g_fLastAngles[3];
	int   g_InvalidButtonSidemoveCount;
	int   g_iCmdNum;
	float g_fLastPosition[3];
	int   g_iLastTeleportTick;
	float g_fAngleDifference[2];
	float g_fLastAngleDifference[2];

	int   g_strafeTick;
	float g_flRawGain;
	bool  g_bTouchesWall;
	int   g_iJump;
	int   g_iTicksOnGround;
	float g_iYawSpeed;
	int   g_iYawTickCount;
	int   g_iTimingTickCount;
	int   g_iStrafesDone;
	bool  g_bFirstSixJumps;

	int   g_iStartStrafe_CurrentFrame;

	//any   g_iStartStrafe_Stats[7][MAX_FRAMES];
	any   g_iStartStrafe_Stats_0[MAX_FRAMES];
	any   g_iStartStrafe_Stats_1[MAX_FRAMES];
	any   g_iStartStrafe_Stats_2[MAX_FRAMES];
	any   g_iStartStrafe_Stats_3[MAX_FRAMES];
	any   g_iStartStrafe_Stats_4[MAX_FRAMES];
	any   g_iStartStrafe_Stats_5[MAX_FRAMES];
	any   g_iStartStrafe_Stats_6[MAX_FRAMES];

	int   g_iStartStrafe_LastRecordedTick;
	int   g_iStartStrafe_LastTickDifference;
	bool  g_bStartStrafe_IsRecorded[MAX_FRAMES];
	int   g_iStartStrafe_IdenticalCount;
	int   g_iEndStrafe_CurrentFrame;

	//any   g_iEndStrafe_Stats[7][MAX_FRAMES];
	any   g_iEndStrafe_Stats_0[MAX_FRAMES];
	any   g_iEndStrafe_Stats_1[MAX_FRAMES];
	any   g_iEndStrafe_Stats_2[MAX_FRAMES];
	any   g_iEndStrafe_Stats_3[MAX_FRAMES];
	any   g_iEndStrafe_Stats_4[MAX_FRAMES];
	any   g_iEndStrafe_Stats_5[MAX_FRAMES];
	any   g_iEndStrafe_Stats_6[MAX_FRAMES];

	int   g_iEndStrafe_LastRecordedTick;
	int   g_iEndStrafe_LastTickDifference;
	bool  g_bEndStrafe_IsRecorded[MAX_FRAMES];
	int   g_iEndStrafe_IdenticalCount;
	int   g_iKeySwitch_CurrentFrame[2];

	//any   g_iKeySwitch_Stats[3][2][MAX_FRAMES_KEYSWITCH];
	any   g_iKeySwitch_Stats_0_0[MAX_FRAMES_KEYSWITCH];
	any   g_iKeySwitch_Stats_0_1[MAX_FRAMES_KEYSWITCH];
	any   g_iKeySwitch_Stats_1_0[MAX_FRAMES_KEYSWITCH];
	any   g_iKeySwitch_Stats_1_1[MAX_FRAMES_KEYSWITCH];
	any   g_iKeySwitch_Stats_2_0[MAX_FRAMES_KEYSWITCH];
	any   g_iKeySwitch_Stats_2_1[MAX_FRAMES_KEYSWITCH];

	//bool  g_bKeySwitch_IsRecorded[2][MAX_FRAMES_KEYSWITCH];
	bool  g_bKeySwitch_IsRecorded_0[MAX_FRAMES_KEYSWITCH];
	bool  g_bKeySwitch_IsRecorded_1[MAX_FRAMES_KEYSWITCH];

	int   g_iKeySwitch_LastRecordedTick[2];
	bool  g_iIllegalTurn[MAX_FRAMES];
	int   g_iIllegalTurn_CurrentFrame;
	bool  g_iIllegalTurn_IsTiming[MAX_FRAMES];
	int   g_iLastIllegalReason;
	int   g_iIllegalSidemoveCount;
	int   g_iLastIllegalSidemoveCount;
	int   g_iLastInvalidButtonCount;
	int   g_iYawChangeCount;
}

bool g_bLateLoad;

Handle g_hTeleport;
bool   g_bDhooksLoaded;

Handle g_fwdOnDetection;
Handle g_fwdOnClientBanned;

ConVar g_hBanLength;
char   g_sBanLength[32];
ConVar g_hAntiNull;
ConVar g_hPrintNullLogs;
ConVar g_hAutoban;
bool g_bAdminMode[MAXPLAYERS + 1];
ConVar g_hQueryRate;
ConVar g_hPersistentData;

char g_aclogfile[PLATFORM_MAX_PATH];
char g_sPlayerIp[MAXPLAYERS + 1][16];

ArrayList g_aPersistentData = null;

public void OnPluginStart() // yeah this is a bit of a mess but ill get around to it at some point sue me
{
	char sDate[64];
	FormatTime(sDate, sizeof(sDate), "%y%m%d", GetTime());

	BuildPath(Path_SM, g_aclogfile, PLATFORM_MAX_PATH, "logs/ac_%s.txt", sDate);

	UserMsg umVGUIMenu = GetUserMessageId("VGUIMenu");
	if (umVGUIMenu == INVALID_MESSAGE_ID)
		SetFailState("UserMsg `umVGUIMenu` not found!");

    g_hBanLength = CreateConVar("bash_banlength", "0", "Ban length for the automated bans", _, true, 0.0); 
    g_hAutoban = CreateConVar("bash_autoban", "1", "Auto ban players who are detected", _, true, 0.0, true, 1.0);
    HookConVarChange(g_hBanLength, OnBanLengthChanged);
    g_hAntiNull = CreateConVar("bash_antinull", "0", "Punish for null movement stats", _, true, 0.0, true, 1.0);
    g_hPrintNullLogs = CreateConVar("bash_print_null_logs", "0", "Should null logs be print to chat?", _, true, 0.0, true, 1.0);
    g_hQueryRate = CreateConVar("bash_query_rate", "1", "How often will convars be queried from the client?", _, true, 0.1, true, 2.0);
    g_hPersistentData = CreateConVar("bash_persistent_data", "1", "Whether to save and reload strafe stats on a map for players when they disconnect.\nThis is useful to prevent people from frequently rejoining to wipe their strafe stats.", _, true, 0.0, true, 1.0);
    g_hLagThreshold = CreateConVar("bash_lag_threshold", "0.02", "Threshold (in seconds) to consider a tick as lagged", _, true, 0.01, true, 1.0);
    g_hMaxLaggedTicks = CreateConVar("bash_max_lagged_ticks", "5", "Maximum number of consecutive lagged ticks before taking action", _, true, 1.0);
    //AutoExecConfig(true, "bash", "sourcemod");
    HookUserMessage(umVGUIMenu, OnVGUIMenu, true);
    g_fwdOnDetection = CreateGlobalForward("Bash_OnDetection", ET_Event, Param_Cell, Param_String);
    g_fwdOnClientBanned = CreateGlobalForward("Bash_OnClientBanned", ET_Event, Param_Cell);

    g_Engine = GetEngineVersion();
    RegAdminCmd("bash2_stats", Bash_Stats, ADMFLAG_RCON, "Check a player's strafe stats");
    RegAdminCmd("bash2_admin", Bash_AdminMode, ADMFLAG_RCON, "Opt in/out of admin mode (Prints bash info into chat).");
    RegAdminCmd("bash2_test", Bash_Test, ADMFLAG_RCON, "trigger a test message so you can know if webhooks are working :)");

    RegAdminCmd("sm_bashhistory", Command_BashHistory, ADMFLAG_BAN, "View a player's BASH history");
    RegAdminCmd("sm_bashstats", Command_BashStats, ADMFLAG_BAN, "View a player's current BASH stats");
    RegAdminCmd("sm_bashreconnectdb", Command_ReconnectDatabase, ADMFLAG_ROOT, "Reconnect to the database"); 

    // Event_PlayerJump thresholds
    g_cvGainThreshold = CreateConVar("bash_gain_threshold", "85.0", "Threshold for gain percentage detection", _, true, 0.0, true, 100.0);
    g_cvYawThreshold = CreateConVar("bash_yaw_threshold", "60.0", "Threshold for yaw percentage detection", _, true, 0.0, true, 100.0);
    g_cvTimingThreshold = CreateConVar("bash_timing_threshold", "100.0", "Threshold for timing percentage detection", _, true, 0.0, true, 100.0); // todo
    HookEvent("player_jump", Event_PlayerJump); 

    // CheckForIllegalTurning and CheckForIllegalMovement thresholds
    g_cvIllegalTurnThreshold = CreateConVar("bash_illegal_turn_threshold", "30", "Threshold for illegal turn detection", _, true, 1.0);
    g_cvIllegalMoveThreshold = CreateConVar("bash_illegal_move_threshold", "4", "Threshold for illegal movement detection", _, true, 1.0);
    g_cvConsistencyThreshold = CreateConVar("bash_consistency_threshold", "0.95", "Threshold for turn consistency detection", _, true, 0.0, true, 1.0);
    g_cvAlternationThreshold = CreateConVar("bash_alternation_threshold", "0.9", "Threshold for turn alternation detection", _, true, 0.0, true, 1.0);

    g_cvDatabaseRetryInterval = CreateConVar("bash_db_retry_interval", "60.0", "Interval in seconds to retry database connection", _, true, 10.0); 
    BuildPath(Path_SM, g_sLogFile, sizeof(g_sLogFile), "logs/bash_db_errors.log");

    g_cvDatabaseConfigName = CreateConVar("bash_database_config", "bash_anticheat", "Name of the database configuration in databases.cfg");
    g_cvDatabaseConfigName.AddChangeHook(OnDatabaseConfigChanged);
    g_hLagThreshold = CreateConVar("bash_lag_threshold", "0.02", "Threshold (in seconds) to consider a tick as lagged", _, true, 0.01, true, 1.0);
    g_hMaxLaggedTicks = CreateConVar("bash_max_lagged_ticks", "5", "Maximum number of consecutive lagged ticks before taking action", _, true, 1.0);

    g_fLagThreshold = g_hLagThreshold.FloatValue;
    g_iMaxLaggedTicks = g_hMaxLaggedTicks.IntValue;

    HookConVarChange(g_hLagThreshold, OnLagThresholdChanged);
    HookConVarChange(g_hMaxLaggedTicks, OnMaxLaggedTicksChanged);

    AutoExecConfig(true, "bash");
    ConnectToDatabase();

    RequestFrame(CheckLag);
}

enum struct PlayerBatchData {
    int client;
    char steam_id[64];
    int total_strafes;
    float avg_gain;
    float max_gain;
    float start_strafe_avg;
    float end_strafe_avg;
    float key_switch_avg;
    int illegal_turns;
    int illegal_moves;
    int suspicious_actions;
}

PlayerBatchData g_BatchData[MAX_BATCH_SIZE];
int g_BatchSize = 0;

void ConnectToDatabase()
{
    if (g_hReconnectTimer != null)
    {
        KillTimer(g_hReconnectTimer);
        g_hReconnectTimer = null;
    }

    g_cvDatabaseConfigName.GetString(g_sDatabaseConfigName, sizeof(g_sDatabaseConfigName));

    char error[255];
    g_hDatabase = SQL_Connect(g_sDatabaseConfigName, true, error, sizeof(error));
    
    if (g_hDatabase == null)
    {
        LogToFile(g_sLogFile, "Failed to connect to database: %s", error);
        
        float retryDelay = INITIAL_RETRY_DELAY * Pow(2.0, float(g_iReconnectAttempts));
        if (retryDelay > MAX_RETRY_DELAY)
        {
            retryDelay = MAX_RETRY_DELAY;
        }
        
        if (g_iReconnectAttempts < MAX_RETRIES)
        {
            g_iReconnectAttempts++;
            LogMessage("Database connection attempt %d failed. Retrying in %.1f seconds...", g_iReconnectAttempts, retryDelay);
            g_hReconnectTimer = CreateTimer(retryDelay, Timer_RetryConnection);
        }
        else
        {
            LogError("Failed to connect to database after %d attempts. Please check your configuration.", MAX_RETRIES);
        }
    }
    else
    {
        g_iReconnectAttempts = 0;
        LogMessage("Successfully connected to database");
        CreateTables();
        
        // Set up ping timer to keep connection alive
        CreateTimer(300.0, Timer_PingDatabase, _, TIMER_REPEAT);
    }
}

public void OnDatabaseConfigChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    strcopy(g_sDatabaseConfigName, sizeof(g_sDatabaseConfigName), newValue);
    
    // reconnect with new config
    if (g_hDatabase != null)
    {
        delete g_hDatabase;
    }
    ConnectToDatabase();
}

public void OnDatabaseConnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogToFile(g_sLogFile, "Database connection failed: %s", error);
        CreateTimer(g_cvDatabaseRetryInterval.FloatValue, Timer_RetryConnection);
        return;
    }

    g_hDatabase = db;
    g_hDatabase.SetCharset("utf8mb4");

    CreateTables();
    LogMessage("Successfully connected to database");
}

public Action Timer_RetryConnection(Handle timer)
{
    g_hReconnectTimer = null;
    ConnectToDatabase();
    return Plugin_Stop;
}

public Action Timer_PingDatabase(Handle timer)
{
    if (g_hDatabase != null)
    {
        g_hDatabase.Query(SQL_PingCallback, "SELECT 1");
    }
    return Plugin_Continue;
}

public void SQL_PingCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
    {
        LogToFile(g_sLogFile, "Database ping failed: %s", error);
        ConnectToDatabase(); // attempt to reconnect
    }
}

public Action Command_ReconnectDatabase(int client, int args)
{
    ReplyToCommand(client, "Attempting to reconnect to the database...");
    ConnectToDatabase();
    return Plugin_Handled;
}

void CreateTables()
{
    char query[] = "CREATE TABLE IF NOT EXISTS player_data ("
        ... "id INT AUTO_INCREMENT PRIMARY KEY, "
        ... "steam_id VARCHAR(64) NOT NULL, "
        ... "timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP, "
        ... "total_strafes INT UNSIGNED DEFAULT 0, "
        ... "avg_gain FLOAT DEFAULT 0, "
        ... "max_gain FLOAT DEFAULT 0, "
        ... "start_strafe_avg FLOAT DEFAULT 0, "
        ... "end_strafe_avg FLOAT DEFAULT 0, "
        ... "key_switch_avg FLOAT DEFAULT 0, "
        ... "illegal_turns INT UNSIGNED DEFAULT 0, "
        ... "illegal_moves INT UNSIGNED DEFAULT 0, "
        ... "suspicious_actions INT UNSIGNED DEFAULT 0, "
        ... "INDEX idx_steam_id (steam_id), "
        ... "INDEX idx_timestamp (timestamp)"
        ... ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;";

    g_hDatabase.Query(SQL_CreateTableCallback, query);
}

public void SQL_CreateTableCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
    {
        LogToFile(g_sLogFile, "Error creating table: %s", error);
    }
}

void UpdatePlayerData(int client)
{
    if (!IsClientConnected(client) || IsFakeClient(client))
        return;

    if (g_BatchSize >= MAX_BATCH_SIZE)
    {
        ProcessBatch();
    }

    char steam_id[64];
    if (!GetClientAuthId(client, AuthId_Steam2, steam_id, sizeof(steam_id)))
        return;

    // data validation
    int total_strafes = g_iStrafesDone[client];
    float avg_gain = GetGainPercent(client);
    float max_gain = GetMaxGain(client);
    float start_strafe_avg = CalculateStartStrafeAvg(client);
    float end_strafe_avg = CalculateEndStrafeAvg(client);
    float key_switch_avg = CalculateKeySwitchAvg(client);
    int illegal_turns = g_iIllegalTurn_CurrentFrame[client];
    int illegal_moves = g_iIllegalSidemoveCount[client];
    int suspicious_actions = CalculateSuspiciousActions(client);

    if (!ValidatePlayerData(total_strafes, avg_gain, max_gain, start_strafe_avg, end_strafe_avg, key_switch_avg, illegal_turns, illegal_moves, suspicious_actions))
    {
        LogToFile(g_sLogFile, "Invalid data for player %L: total_strafes=%d, avg_gain=%.2f, max_gain=%.2f, start_strafe_avg=%.2f, end_strafe_avg=%.2f, key_switch_avg=%.2f, illegal_turns=%d, illegal_moves=%d, suspicious_actions=%d",
            client, total_strafes, avg_gain, max_gain, start_strafe_avg, end_strafe_avg, key_switch_avg, illegal_turns, illegal_moves, suspicious_actions);
        return;
    }

    g_BatchData[g_BatchSize].client = client;
    strcopy(g_BatchData[g_BatchSize].steam_id, 64, steam_id);
    g_BatchData[g_BatchSize].total_strafes = total_strafes;
    g_BatchData[g_BatchSize].avg_gain = avg_gain;
    g_BatchData[g_BatchSize].max_gain = max_gain;
    g_BatchData[g_BatchSize].start_strafe_avg = start_strafe_avg;
    g_BatchData[g_BatchSize].end_strafe_avg = end_strafe_avg;
    g_BatchData[g_BatchSize].key_switch_avg = key_switch_avg;
    g_BatchData[g_BatchSize].illegal_turns = illegal_turns;
    g_BatchData[g_BatchSize].illegal_moves = illegal_moves;
    g_BatchData[g_BatchSize].suspicious_actions = suspicious_actions;

    g_BatchSize++;
}

bool ValidatePlayerData(int total_strafes, float avg_gain, float max_gain, float start_strafe_avg, float end_strafe_avg, float key_switch_avg, int illegal_turns, int illegal_moves, int suspicious_actions)
{
    return (total_strafes >= 0 && 
            0.0 <= avg_gain <= 100.0 && 
            0.0 <= max_gain <= 100.0 &&
            start_strafe_avg >= 0.0 && 
            end_strafe_avg >= 0.0 && 
            key_switch_avg >= 0.0 && 
            illegal_turns >= 0 && 
            illegal_moves >= 0 &&
            suspicious_actions >= 0);
}

void ProcessBatch()
{
    if (g_BatchSize == 0)
        return;

    Transaction transaction = new Transaction();

    char query[1024];
    for (int i = 0; i < g_BatchSize; i++)
    {
        g_hDatabase.Format(query, sizeof(query),
            "INSERT INTO player_data (steam_id, total_strafes, avg_gain, max_gain, start_strafe_avg, end_strafe_avg, key_switch_avg, illegal_turns, illegal_moves, suspicious_actions) "
            ... "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) "
            ... "ON DUPLICATE KEY UPDATE "
            ... "total_strafes = VALUES(total_strafes), "
            ... "avg_gain = VALUES(avg_gain), "
            ... "max_gain = VALUES(max_gain), "
            ... "start_strafe_avg = VALUES(start_strafe_avg), "
            ... "end_strafe_avg = VALUES(end_strafe_avg), "
            ... "key_switch_avg = VALUES(key_switch_avg), "
            ... "illegal_turns = VALUES(illegal_turns), "
            ... "illegal_moves = VALUES(illegal_moves), "
            ... "suspicious_actions = VALUES(suspicious_actions)");

        DataPack pack = new DataPack();
        pack.WriteString(g_BatchData[i].steam_id);
        pack.WriteCell(g_BatchData[i].total_strafes);
        pack.WriteFloat(g_BatchData[i].avg_gain);
        pack.WriteFloat(g_BatchData[i].max_gain);
        pack.WriteFloat(g_BatchData[i].start_strafe_avg);
        pack.WriteFloat(g_BatchData[i].end_strafe_avg);
        pack.WriteFloat(g_BatchData[i].key_switch_avg);
        pack.WriteCell(g_BatchData[i].illegal_turns);
        pack.WriteCell(g_BatchData[i].illegal_moves);
        pack.WriteCell(g_BatchData[i].suspicious_actions);

        transaction.AddQuery(query, pack);
    }

    g_hDatabase.Execute(transaction, SQL_OnTransactionSuccess, SQL_OnTransactionFailure, _, DBPrio_Low);
    g_BatchSize = 0;
}

public void SQL_OnTransactionSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
    LogMessage("Successfully updated data for %d players", numQueries);

    // clean up datapacks
    for (int i = 0; i < numQueries; i++)
    {
        delete view_as<DataPack>(queryData[i]);
    }
}

public void SQL_OnTransactionFailure(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    LogToFile(g_sLogFile, "Failed to update data for batch: %s (Query %d of %d)", error, failIndex + 1, numQueries);

    // clean up datapacks
    for (int i = 0; i < numQueries; i++)
    {
        delete view_as<DataPack>(queryData[i]);
    }
}

float CalculateStartStrafeAvg(int client)
{
    int count = 0;
    float total = 0.0;
    for (int i = 0; i < MAX_FRAMES; i++)
    {
        if (g_bStartStrafe_IsRecorded[client][i])
        {
            total += float(g_iStartStrafe_Stats[client][StrafeData_Difference][i]);
            count++;
        }
    }
    return (count > 0) ? (total / float(count)) : 0.0;
}

float CalculateEndStrafeAvg(int client)
{
    int count = 0;
    float total = 0.0;
    for (int i = 0; i < MAX_FRAMES; i++)
    {
        if (g_bEndStrafe_IsRecorded[client][i])
        {
            total += float(g_iEndStrafe_Stats[client][StrafeData_Difference][i]);
            count++;
        }
    }
    return (count > 0) ? (total / float(count)) : 0.0;
}

float CalculateKeySwitchAvg(int client)
{
    int count = 0;
    float total = 0.0;
    for (int i = 0; i < MAX_FRAMES_KEYSWITCH; i++)
    {
        if (g_bKeySwitch_IsRecorded[client][BT_Move][i])
        {
            total += float(g_iKeySwitch_Stats[client][KeySwitchData_Difference][BT_Move][i]);
            count++;
        }
    }
    return (count > 0) ? (total / float(count)) : 0.0;
}

float GetMaxGain(int client)
{
    float max_gain = 0.0;
    for (int i = 0; i < MAX_FRAMES; i++)
    {
        if (g_bStartStrafe_IsRecorded[client][i])
        {
            float gain = float(g_iStartStrafe_Stats[client][StrafeData_Difference][i]);
            if (gain > max_gain)
                max_gain = gain;
        }
        if (g_bEndStrafe_IsRecorded[client][i])
        {
            float gain = float(g_iEndStrafe_Stats[client][StrafeData_Difference][i]);
            if (gain > max_gain)
                max_gain = gain;
        }
    }
    return max_gain;
}

int CalculateSuspiciousActions(int client)
{
    // todo: add more
    return g_iIllegalTurn_CurrentFrame[client] + g_iIllegalSidemoveCount[client];
}

public void SQL_BatchCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
    {
        LogError("Batch query failed: %s", error);
    }
    else
    {
        LogMessage("Successfully updated %d player records", results.RowCount);
    }
}

public void SQL_BatchErrorCallback(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    LogError("Error in batch update (query %d): %s", failIndex, error);
}

public Action Command_BashHistory(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[SM] Usage: sm_bashhistory <name|#userid|steam_id>");
        return Plugin_Handled;
    }

    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));

    int target = FindTarget(client, arg, true, false);
    if (target == -1)
    {
        // FindTarget() automatically replies with the appropriate error message
        return Plugin_Handled;
    }

    char steam_id[64];
    if (!GetClientAuthId(target, AuthId_Steam2, steam_id, sizeof(steam_id)))
    {
        ReplyToCommand(client, "[SM] Couldn't get Steam ID for player.");
        return Plugin_Handled;
    }

    char query[512];
    g_hDatabase.Format(query, sizeof(query), 
        "SELECT timestamp, avg_gain, max_gain, start_strafe_avg, end_strafe_avg, key_switch_avg, illegal_turns, illegal_moves, suspicious_actions "
        ... "FROM player_data WHERE steam_id = ? ORDER BY timestamp DESC LIMIT 10");

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteString(steam_id);

    g_hDatabase.Query(SQL_BashHistoryCallback, query, pack);

    return Plugin_Handled;
}

public void SQL_BashHistoryCallback(Database db, DBResultSet results, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int clientUserId = pack.ReadCell();
    char steam_id[64];
    pack.ReadString(steam_id, sizeof(steam_id));
    delete pack;

    int client = GetClientOfUserId(clientUserId);
    if (client == 0)
        return;

    if (results == null)
    {
        ReplyToCommand(client, "[SM] Query failed: %s", error);
        return;
    }

    if (results.RowCount == 0)
    {
        ReplyToCommand(client, "[SM] No history found for Steam ID %s", steam_id);
        return;
    }

    ReplyToCommand(client, "BASH History for %s:", steam_id);
    ReplyToCommand(client, "Timestamp | AvgGain | MaxGain | StartAvg | EndAvg | KeySwitchAvg | IllegalTurns | IllegalMoves | SuspiciousActions");

    while (results.FetchRow())
    {
        char timestamp[64];
        results.FetchString(0, timestamp, sizeof(timestamp));
        float avg_gain = results.FetchFloat(1);
        float max_gain = results.FetchFloat(2);
        float start_avg = results.FetchFloat(3);
        float end_avg = results.FetchFloat(4);
        float key_switch_avg = results.FetchFloat(5);
        int illegal_turns = results.FetchInt(6);
        int illegal_moves = results.FetchInt(7);
        int suspicious_actions = results.FetchInt(8);

        ReplyToCommand(client, "%s | %.2f | %.2f | %.2f | %.2f | %.2f | %d | %d | %d",
            timestamp, avg_gain, max_gain, start_avg, end_avg, key_switch_avg, illegal_turns, illegal_moves, suspicious_actions);
    }
}

public void OnPluginEnd()
{
    if (g_hDatabase != null)
    {
        delete g_hDatabase;
    }
}

public Action Command_BashStats(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[SM] Usage: sm_bashstats <name|#userid>");
        return Plugin_Handled;
    }

    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));

    int target = FindTarget(client, arg, true, false);
    if (target == -1)
    {
        // FindTarget() automatically replies with the appropriate error message
        return Plugin_Handled;
    }

    ReplyToCommand(client, "Current BASH Stats for %N:", target);
    ReplyToCommand(client, "Total Strafes: %d", g_iStrafesDone[target]);
    ReplyToCommand(client, "Average Gain: %.2f", GetGainPercent(target));
    ReplyToCommand(client, "Start Strafe Avg: %.2f", CalculateStartStrafeAvg(target));
    ReplyToCommand(client, "End Strafe Avg: %.2f", CalculateEndStrafeAvg(target));
    ReplyToCommand(client, "Key Switch Avg: %.2f", CalculateKeySwitchAvg(target));
    ReplyToCommand(client, "Illegal Turns: %d", g_iIllegalTurn_CurrentFrame[target]);
    ReplyToCommand(client, "Illegal Moves: %d", g_iIllegalSidemoveCount[target]);
    ReplyToCommand(client, "Suspicious Actions: %d", CalculateSuspiciousActions(target));

    return Plugin_Handled;
}

public void OnConfigsExecuted()
{
	GetConVarString(g_hBanLength, g_sBanLength, sizeof(g_sBanLength));
}

public void OnBanLengthChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	strcopy(g_sBanLength, sizeof(g_sBanLength), newValue);
}

public void OnAllPluginsLoaded()
{

	if(g_hTeleport == INVALID_HANDLE && LibraryExists("dhooks"))
	{
		Initialize();
		g_bDhooksLoaded = true;
	}
}

public void OnLibraryAdded(const char[] name)
{
	if(StrEqual(name, "dhooks") && g_hTeleport == INVALID_HANDLE)
	{
		Initialize();
		g_bDhooksLoaded = true;
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if(StrEqual(name, "dhooks"))
	{
		g_bDhooksLoaded = false;
	}
}

stock void PrintToAdmins(const char[] msg, any...)
{
    if (!msg){
        return;
    }

    char buffer[300];
    VFormat(buffer, sizeof(buffer), msg, 2);

    for (int i = 1; i <= MaxClients; i++)
	{
		if (CheckCommandAccess(i, "bash2_chat_log", ADMFLAG_RCON))
		{
			if(g_bAdminMode[i]) {
				PrintToChat(i, buffer);
			}
		}
	}
}

void Initialize()
{
	Handle hGameData = LoadGameConfigFile("sdktools.games");
	if(hGameData == INVALID_HANDLE)
		return;

	int iOffset = GameConfGetOffset(hGameData, "Teleport");

	CloseHandle(hGameData);

	if(iOffset == -1)
		return;

	g_hTeleport = DHookCreate(iOffset, HookType_Entity, ReturnType_Void, ThisPointer_CBaseEntity, Hook_DHooks_Teleport);

	if(g_hTeleport == INVALID_HANDLE){
		PrintToServer("\n!! g_hTeleport -> INVALID_HANDLE !!\n");
		return;
	}

	DHookAddParam(g_hTeleport, HookParamType_VectorPtr);
	DHookAddParam(g_hTeleport, HookParamType_ObjectPtr);
	DHookAddParam(g_hTeleport, HookParamType_VectorPtr);

	if(g_Engine == Engine_CSGO)
		DHookAddParam(g_hTeleport, HookParamType_Bool); // CS:GO only
}

public MRESReturn Hook_DHooks_Teleport(int client, Handle hParams) // still not entirely sure what this actually does
{
	if(!IsClientConnected(client) || IsFakeClient(client) || !IsPlayerAlive(client))
		return MRES_Ignored;

	g_iLastTeleportTick[client] = g_iCmdNum[client];

	return MRES_Ignored;
}

void AutoBanPlayer(int client)
{
    if (g_hAutoban.BoolValue && IsClientInGame(client) && !IsClientInKickQueue(client))
    {
        char steam_id[64];
        if (GetClientAuthId(client, AuthId_Steam2, steam_id, sizeof(steam_id)))
        {
            char query[256];
            g_hDatabase.Format(query, sizeof(query), "INSERT INTO banned_players (steam_id, ban_length, reason) VALUES (?, ?, 'Cheating')");
            
            DataPack pack = new DataPack();
            pack.WriteString(steam_id);
            pack.WriteString(g_sBanLength);
            
            g_hDatabase.Query(SQL_AutoBanPlayerCallback, query, pack);
        }
        else
        {
            LogError("Failed to get SteamID for client %d during auto-ban", client);
        }

        Call_StartForward(g_fwdOnClientBanned);
        Call_PushCell(client);
        Call_Finish();
    }
}

public void SQL_AutoBanPlayerCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
    {
        DataPack pack = view_as<DataPack>(data);
        pack.Reset();
        char steam_id[32];
        pack.ReadString(steam_id, sizeof(steam_id));
        char ban_length[32];
        pack.ReadString(ban_length, sizeof(ban_length));
        delete pack;

        LogError("Failed to insert ban for SteamID %s: %s", steam_id, error);
    }
    else
    {
        // ban successfully inserted into database
		// do something else here
        DataPack pack = view_as<DataPack>(data);
        pack.Reset();
        char steam_id[32];
        pack.ReadString(steam_id, sizeof(steam_id));
        delete pack;

        int client = GetClientBySteamID(steam_id);
        if (client != -1)
        {
            KickClient(client, "You have been banned for cheating");
        }
    }
}

int GetClientBySteamID(const char[] steam_id)
{
    char client_steam_id[32];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientConnected(i) && !IsFakeClient(i))
        {
            if (GetClientAuthId(i, AuthId_Steam2, client_steam_id, sizeof(client_steam_id)))
            {
                if (StrEqual(steam_id, client_steam_id))
                {
                    return i;
                }
            }
        }
    }
    return -1;
}

public void OnLagThresholdChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    g_fLagThreshold = g_hLagThreshold.FloatValue;
}

public void OnMaxLaggedTicksChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    g_iMaxLaggedTicks = g_hMaxLaggedTicks.IntValue;
}

void CheckLag(any data)
{
    float currentTime = GetEngineTime();
    float timeSinceLastCheck = currentTime - g_fLag_LastCheckTime;

    if (timeSinceLastCheck > g_fLagThreshold)
    {
        g_iLaggedTicks++;
        g_fLastLagTime = currentTime; // to do
        UpdateLagHistory(timeSinceLastCheck);

        if (g_iLaggedTicks >= g_iMaxLaggedTicks)
        {
            HandleSevereLagSpike(timeSinceLastCheck);
        }
        else
        {
            AdjustAntiCheatThresholds(true);
        }
    }
    else
    {
        g_iLaggedTicks = 0;
        AdjustAntiCheatThresholds(false);
    }

    g_fLag_LastCheckTime = currentTime;
    AnalyzeLagPatterns();

    RequestFrame(CheckLag);
}

void UpdateLagHistory(float lagDuration)
{
    g_fLagHistory[g_iLagHistoryIndex] = lagDuration;
    g_iLagHistoryIndex = (g_iLagHistoryIndex + 1) % LAG_HISTORY_SIZE;
}

void HandleSevereLagSpike(float lagDuration)
{
    g_bSevereLatgSpike = true;

    // log the lag spike
    LogMessage("Severe lag spike detected: %f seconds, %d consecutive lagged ticks", lagDuration, g_iLaggedTicks);

    // notify admins
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && CheckCommandAccess(i, "bash2_chat_log", ADMFLAG_RCON) && g_bAdminMode[i])
        {
            PrintToChat(i, "[BASH] Severe lag spike detected: %.2f seconds, %d consecutive lagged ticks", lagDuration, g_iLaggedTicks);
        }
    }

    // temporarily disable certain anti-cheat checks
    DisableAntiCheatChecks();

    // schedule re-enabling of anti-cheat checks
    CreateTimer(5.0, Timer_ReenableAntiCheatChecks);
}

void AdjustAntiCheatThresholds(bool isLagging)
{
    if (isLagging)
    {
        // increase thresholds during lag
        g_fNormalThresholdMultiplier = g_fLagThresholdMultiplier;
    }
    else
    {
        // reset thresholds when not lagging
        g_fNormalThresholdMultiplier = 1.0;
    }

    // adjust specific thresholds
    g_cvGainThreshold.FloatValue *= g_fNormalThresholdMultiplier;
    g_cvYawThreshold.FloatValue *= g_fNormalThresholdMultiplier;
    g_cvTimingThreshold.FloatValue *= g_fNormalThresholdMultiplier;
    g_cvIllegalTurnThreshold.FloatValue *= g_fNormalThresholdMultiplier;
    g_cvIllegalMoveThreshold.FloatValue *= g_fNormalThresholdMultiplier;
}

void DisableAntiCheatChecks()
{
    // disable specific anti-cheat checks during severe lag spikes
    // should we really do this?
    LogMessage("Temporarily disabling certain anti-cheat checks due to severe lag");
}

public Action Timer_ReenableAntiCheatChecks(Handle timer)
{
    // re-enable anti-cheat checks
    g_bSevereLatgSpike = false;
    LogMessage("Re-enabling anti-cheat checks after lag spike");
    return Plugin_Stop;
}

void AnalyzeLagPatterns()
{
    float averageLag = 0.0;
    float maxLag = 0.0;
    int significantLagSpikes = 0;

    for (int i = 0; i < LAG_HISTORY_SIZE; i++)
    {
        averageLag += g_fLagHistory[i];
        if (g_fLagHistory[i] > maxLag)
        {
            maxLag = g_fLagHistory[i];
        }
        if (g_fLagHistory[i] > g_fLagThreshold * 2)
        {
            significantLagSpikes++;
        }
    }

    averageLag /= LAG_HISTORY_SIZE;

    // analyze the lag pattern and take appropriate action
    if (averageLag > g_fLagThreshold * 1.5 || significantLagSpikes > LAG_HISTORY_SIZE / 4)
    {
        LogMessage("Persistent lag detected. Average: %.2f, Max: %.2f, Significant spikes: %d", averageLag, maxLag, significantLagSpikes);
        // consider taking more drastic actions here, such as temporarily disabling the anti-cheat or notifying server admins
    }
}

void SaveOldLogs() // todo: handle multiple days and compress old logs
{
	char sDate[64];
	FormatTime(sDate, sizeof(sDate), "%y%m%d", GetTime() - (60 * 60 * 24)); // save logs from day before to new file
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "logs/ac_%s.txt", sDate);

	if(!FileExists(sPath))
	{
		return;
	}

	char sNewPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sNewPath, sizeof(sNewPath), "logs/bash.txt");

	File hOld = OpenFile(sPath, "r");
	File hNew = OpenFile(sNewPath, "a");

	if(hOld == INVALID_HANDLE)
	{
		LogError("Couldn't open '%s'", sPath);
		return;
	}

	if(hNew == INVALID_HANDLE)
	{
		LogError("Couldn't open '%s'", sNewPath);
		return;
	}

	char sDateFormatted[64];
	FormatTime(sDateFormatted, sizeof(sDateFormatted), "%y-%m-%d", GetTime() - (60 * 60 * 24));
	WriteFileLine(hNew, "\n***** ------------ Logs from %s ------------ *****", sDateFormatted);

	char sLine[256];
	while(!IsEndOfFile(hOld))
	{
		if(ReadFileLine(hOld, sLine, sizeof(sLine)))
		{
			ReplaceString(sLine, sizeof(sLine), "\n", "");
			WriteFileLine(hNew, sLine);
		}
	}

	delete hOld;
	delete hNew;
	DeleteFile(sPath);
}

stock bool AnticheatLog(int client, const char[] log, any ...)
{
	char buffer[1024];
	VFormat(buffer, sizeof(buffer), log, 3);

	Call_StartForward(g_fwdOnDetection);
	Call_PushCell(client);
	Call_PushString(buffer);
	Call_Finish();

	LogToFile(g_aclogfile, "%L<%s> %s", client, g_sPlayerIp[client], buffer);

	if (!g_hPrintNullLogs.BoolValue && StrContains(buffer, "nullPct") != -1)
	{
		return;
	}

	PrintToAdmins("%N %s", client, buffer);
}

public Action Event_PlayerJump(Event event, const char[] name, bool dontBroadcast) // more cvars here
{
    int iclient = GetClientOfUserId(GetEventInt(event, "userid"));

    if(++g_iJump[iclient] == 6)
    {
        float gainPct = GetGainPercent(iclient);
        float yawPct = (g_strafeTick[iclient] > 0) ? (float(g_iYawTickCount[iclient]) / float(g_strafeTick[iclient])) * 100.0 : 0.0; // lets not divide by 0
        float timingPct = (g_strafeTick[iclient] > 0) ? (float(g_iTimingTickCount[iclient]) / float(g_strafeTick[iclient])) * 100.0 : 0.0;

        float spj;
        if(g_bFirstSixJumps[iclient])
            spj = g_iStrafesDone[iclient] / 5.0;
        else
            spj = g_iStrafesDone[iclient] / 6.0;

        if(g_strafeTick[iclient] > 300)
        {
            if(gainPct > g_cvGainThreshold.FloatValue && yawPct < g_cvYawThreshold.FloatValue) // here
            {
                AnticheatLog(iclient, "has %.2f％ gains (Yawing %.1f％, Timing: %.1f％, SPJ: %.1f)", gainPct, yawPct, timingPct, spj);

                if(gainPct == 100.0 && timingPct == 100.0)
                {
                    AutoBanPlayer(iclient);
                }
            }
        }

        g_iJump[iclient] = 0;
        g_flRawGain[iclient] = 0.0;
        g_strafeTick[iclient] = 0;
        g_iYawTickCount[iclient] = 0;
        g_iTimingTickCount[iclient] = 0;
        g_iStrafesDone[iclient] = 0;
        g_bFirstSixJumps[iclient] = false;
    }
}

public Action OnVGUIMenu(UserMsg msg_id, Handle msg, const int[] players, int playersNum, bool reliable, bool init)
{
    int client = players[0];

    if (g_bMOTDTest[client])
    {
        GetClientEyeAngles(client, g_MOTDTestAngles[client]);
        CreateTimer(0.1, Timer_MOTD, GetClientUserId(client));
    }

    // use the newer user message API
    BfRead bf = UserMessageToBfRead(msg);
    char panelName[64];
    bf.ReadString(panelName, sizeof(panelName));

    // should add more specific handling for different panel types here 
    // example:
    // if (StrEqual(panelName, "info"))
    // {
    //     Handle info panel
    // }

    return Plugin_Continue;
}

public Action Timer_MOTD(Handle timer, any data)
{
    int client = GetClientOfUserId(data);

    if (client != 0)
    {
        float vAng[3];
        GetClientEyeAngles(client, vAng);
        
        // improved angle check
        float angleDifference = GetAngleDifference(g_MOTDTestAngles[client][1], vAng[1]);
        
        if (angleDifference > 50.0)
        {
            char clientName[MAX_NAME_LENGTH];
            GetClientName(client, clientName, sizeof(clientName));
            
            char clientAuth[32];
            GetClientAuthId(client, AuthId_Steam2, clientAuth, sizeof(clientAuth));
            
            char clientIP[32];
            GetClientIP(client, clientIP, sizeof(clientIP));
            
            LogToFile(g_aclogfile, "Possible strafe hack detected: %s (%s) - IP: %s - Angle difference: %.2f", clientName, clientAuth, clientIP, angleDifference);
            PrintToAdmins("%N is possibly using a strafe hack (Angle difference: %.2f)", client, angleDifference);
            
            // add more actions here, maybe ban or something after i know it works
        }
        g_bMOTDTest[client] = false;
    }
}

float GetAngleDifference(float angle1, float angle2)
{
    float diff = FloatAbs(angle1 - angle2);
    return (diff > 180.0) ? 360.0 - diff : diff;
}

public void OnMapEnd()
{
	for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
        {
            UpdatePlayerData(i);
        }
    }
	ProcessBatch();
}

public void OnMapStart() // probably needs more cleanup
{
	delete g_aPersistentData;
	g_aPersistentData = new ArrayList(sizeof(fuck_sourcemod));

	CreateTimer(g_hQueryRate.FloatValue, Timer_UpdateYaw, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

	if(g_bLateLoad)
	{
		for(int iclient = 1; iclient <= MaxClients; iclient++)
		{
			if(IsClientInGame(iclient))
			{
				OnClientConnected(iclient);
				OnClientPutInServer(iclient);
			}
		}
	}

	SaveOldLogs();
}

public Action Timer_UpdateYaw(Handle timer, any data) // hmmmmmmmmm this isnt so bad but at the end of the day its gotta go
{
	for(int iclient = 1; iclient <= MaxClients; iclient++)
	{
		if(IsClientInGame(iclient) && !IsFakeClient(iclient))
		{
			QueryForCvars(iclient);
		}
	}
}

public void OnClientConnected(int client) // this needs to be optimized, we're gonna get memory issues at some point
{
	if(IsFakeClient(client))
		return;

	GetClientIP(client, g_sPlayerIp[client], 16);

	for(int idx; idx < MAX_FRAMES; idx++)
	{
		g_bStartStrafe_IsRecorded[client][idx]         = false;
		g_bEndStrafe_IsRecorded[client][idx]           = false;
	}

	for(int idx; idx < MAX_FRAMES_KEYSWITCH; idx++)
	{
		g_bKeySwitch_IsRecorded[client][BT_Key][idx]   = false;
		g_bKeySwitch_IsRecorded[client][BT_Move][idx]  = false;
	}

	g_iStartStrafe_CurrentFrame[client]        = 0;
	g_iEndStrafe_CurrentFrame[client]          = 0;
	g_iKeySwitch_CurrentFrame[client][BT_Key]  = 0;
	g_iKeySwitch_CurrentFrame[client][BT_Move] = 0;
	g_bCheckedYet[client] = false;
	g_iStartStrafe_LastTickDifference[client] = 0;
	g_iEndStrafe_LastTickDifference[client] = 0;
	g_iStartStrafe_IdenticalCount[client] = 0;
	g_iEndStrafe_IdenticalCount[client]   = 0;

	g_iYawSpeed[client] = 210.0;
	g_mYaw[client] = 0.0;
	g_mYawChangedCount[client] = 0;
	g_mYawCheckedCount[client] = 0;
	g_mFilter[client] = false;
	g_mFilterChangedCount[client] = 0;
	g_mFilterCheckedCount[client] = 0;
	g_mRawInput[client] = true;
	g_mRawInputChangedCount[client] = 0;
	g_mRawInputCheckedCount[client] = 0;
	g_mCustomAccel[client] = 0;
	g_mCustomAccelChangedCount[client] = 0;
	g_mCustomAccelCheckedCount[client] = 0;
	g_mCustomAccelMax[client] = 0.0;
	g_mCustomAccelMaxChangedCount[client] = 0;
	g_mCustomAccelMaxCheckedCount[client] = 0;
	g_mCustomAccelScale[client] = 0.0;
	g_mCustomAccelScaleChangedCount[client] = 0;
	g_mCustomAccelScaleCheckedCount[client] = 0;
	g_mCustomAccelExponent[client] = 0.0;
	g_mCustomAccelExponentChangedCount[client] = 0;
	g_mCustomAccelExponentCheckedCount[client] = 0;
	g_Sensitivity[client] = 0.0;
	g_SensitivityChangedCount[client] = 0;
	g_SensitivityCheckedCount[client] = 0;
	g_JoySensitivity[client] = 0.0;
	g_JoySensitivityChangedCount[client] = 0;
	g_JoySensitivityCheckedCount[client] = 0;
	g_ZoomSensitivity[client] = 0.0;
	g_ZoomSensitivityChangedCount[client] = 0;
	g_ZoomSensitivityCheckedCount[client] = 0;

	g_iLastInvalidButtonCount[client] = 0;

	g_JoyStick[client] = false;
	g_JoyStickChangedCount[client] = 0;
}

public void OnClientPostAdminCheck(int client) // this needs to be optimized, we're gonna get memory issues at some point
{
	if (CheckCommandAccess(client, "bash2_chat_log", ADMFLAG_RCON))
	{
		g_bAdminMode[client] = true;
	}

	if(IsFakeClient(client))
		return;

	if (!g_hPersistentData.BoolValue)
		return;

	int index = g_aPersistentData.FindValue(GetSteamAccountID(client));

	if (index != -1)
	{
		fuck_sourcemod x;
		g_aPersistentData.GetArray(index, x);
		g_aPersistentData.Erase(index);

		g_iRealButtons[client] = x.g_iRealButtons;
		g_iButtons[client] = x.g_iButtons;
		g_iLastButtons[client] = x.g_iLastButtons;

		g_iLastPressTick[client][0] = x.g_iLastPressTick_0;
		g_iLastPressTick[client][1] = x.g_iLastPressTick_1;
		g_iLastPressTick[client][2] = x.g_iLastPressTick_2;
		g_iLastPressTick[client][3] = x.g_iLastPressTick_3;

		g_iLastPressTick_Recorded[client][0] = x.g_iLastPressTick_Recorded_0;
		g_iLastPressTick_Recorded[client][1] = x.g_iLastPressTick_Recorded_1;
		g_iLastPressTick_Recorded[client][2] = x.g_iLastPressTick_Recorded_2;
		g_iLastPressTick_Recorded[client][3] = x.g_iLastPressTick_Recorded_3;

		g_iLastPressTick_Recorded_KS[client][0] = x.g_iLastPressTick_Recorded_KS_0;
		g_iLastPressTick_Recorded_KS[client][1] = x.g_iLastPressTick_Recorded_KS_1;
		g_iLastPressTick_Recorded_KS[client][3] = x.g_iLastPressTick_Recorded_KS_2;
		g_iLastPressTick_Recorded_KS[client][3] = x.g_iLastPressTick_Recorded_KS_3;

		g_iKeyPressesThisStrafe[client] = x.g_iKeyPressesThisStrafe;

		g_iLastReleaseTick[client][0] = x.g_iLastReleaseTick_0;
		g_iLastReleaseTick[client][1] = x.g_iLastReleaseTick_1;
		g_iLastReleaseTick[client][2] = x.g_iLastReleaseTick_2;
		g_iLastReleaseTick[client][3] = x.g_iLastReleaseTick_3;

		g_iLastReleaseTick_Recorded[client][0] = x.g_iLastReleaseTick_Recorded_0;
		g_iLastReleaseTick_Recorded[client][1] = x.g_iLastReleaseTick_Recorded_1;
		g_iLastReleaseTick_Recorded[client][2] = x.g_iLastReleaseTick_Recorded_2;
		g_iLastReleaseTick_Recorded[client][3] = x.g_iLastReleaseTick_Recorded_3;

		g_iLastReleaseTick_Recorded_KS[client][0] = x.g_iLastReleaseTick_Recorded_KS_0;
		g_iLastReleaseTick_Recorded_KS[client][1] = x.g_iLastReleaseTick_Recorded_KS_1;
		g_iLastReleaseTick_Recorded_KS[client][2] = x.g_iLastReleaseTick_Recorded_KS_2;
		g_iLastReleaseTick_Recorded_KS[client][3] = x.g_iLastReleaseTick_Recorded_KS_3;

		g_fLastMove[client] = x.g_fLastMove;
		g_iLastTurnDir[client] = x.g_iLastTurnDir;
		g_iLastTurnTick[client] = x.g_iLastTurnTick;
		g_iLastTurnTick_Recorded_StartStrafe[client] = x.g_iLastTurnTick_Recorded_StartStrafe;
		g_iLastTurnTick_Recorded_EndStrafe[client] = x.g_iLastTurnTick_Recorded_EndStrafe;
		g_iLastStopTurnTick[client] = x.g_iLastStopTurnTick;
		//g_bIsTurning[client] = x.g_bIsTurning;
		g_iReleaseTickAtLastEndStrafe[client] = x.g_iReleaseTickAtLastEndStrafe;
		g_fLastAngles[client] = x.g_fLastAngles;
		g_InvalidButtonSidemoveCount[client] = x.g_InvalidButtonSidemoveCount;
		g_iCmdNum[client] = x.g_iCmdNum;
		g_fLastPosition[client] = x.g_fLastPosition;
		//g_iLastTeleportTick[client] = x.g_iLastTeleportTick;
		g_fAngleDifference[client] = x.g_fAngleDifference;
		g_fLastAngleDifference[client] = x.g_fLastAngleDifference;

		g_strafeTick[client] = x.g_strafeTick;
		g_flRawGain[client] = x.g_flRawGain;
		g_bTouchesWall[client] = x.g_bTouchesWall;
		g_iJump[client] = x.g_iJump;
		g_iTicksOnGround[client] = x.g_iTicksOnGround;
		g_iYawSpeed[client] = x.g_iYawSpeed;
		g_iYawTickCount[client] = x.g_iYawTickCount;
		g_iTimingTickCount[client] = x.g_iTimingTickCount;
		g_iStrafesDone[client] = x.g_iStrafesDone;
		g_bFirstSixJumps[client] = x.g_bFirstSixJumps;

		g_iStartStrafe_CurrentFrame[client] = x.g_iStartStrafe_CurrentFrame;

		g_iStartStrafe_Stats[client][0] = x.g_iStartStrafe_Stats_0;
		g_iStartStrafe_Stats[client][1] = x.g_iStartStrafe_Stats_1;
		g_iStartStrafe_Stats[client][2] = x.g_iStartStrafe_Stats_2;
		g_iStartStrafe_Stats[client][3] = x.g_iStartStrafe_Stats_3;
		g_iStartStrafe_Stats[client][4] = x.g_iStartStrafe_Stats_4;
		g_iStartStrafe_Stats[client][5] = x.g_iStartStrafe_Stats_5;
		g_iStartStrafe_Stats[client][6] = x.g_iStartStrafe_Stats_6;

		g_iStartStrafe_LastRecordedTick[client] = x.g_iStartStrafe_LastRecordedTick;
		g_iStartStrafe_LastTickDifference[client] = x.g_iStartStrafe_LastTickDifference;
		g_bStartStrafe_IsRecorded[client] = x.g_bStartStrafe_IsRecorded;
		g_iStartStrafe_IdenticalCount[client] = x.g_iStartStrafe_IdenticalCount;

		g_iEndStrafe_CurrentFrame[client] = x.g_iEndStrafe_CurrentFrame;

		g_iEndStrafe_Stats[client][0] = x.g_iEndStrafe_Stats_0;
		g_iEndStrafe_Stats[client][1] = x.g_iEndStrafe_Stats_1;
		g_iEndStrafe_Stats[client][2] = x.g_iEndStrafe_Stats_2;
		g_iEndStrafe_Stats[client][3] = x.g_iEndStrafe_Stats_3;
		g_iEndStrafe_Stats[client][4] = x.g_iEndStrafe_Stats_4;
		g_iEndStrafe_Stats[client][5] = x.g_iEndStrafe_Stats_5;
		g_iEndStrafe_Stats[client][6] = x.g_iEndStrafe_Stats_6;

		g_iEndStrafe_LastRecordedTick[client] = x.g_iEndStrafe_LastRecordedTick;
		g_iEndStrafe_LastTickDifference[client] = x.g_iEndStrafe_LastTickDifference;
		g_bEndStrafe_IsRecorded[client] = x.g_bEndStrafe_IsRecorded;
		g_iEndStrafe_IdenticalCount[client] = x.g_iEndStrafe_IdenticalCount;
		g_iKeySwitch_CurrentFrame[client] = x.g_iKeySwitch_CurrentFrame;

		g_iKeySwitch_Stats[client][0][0] = x.g_iKeySwitch_Stats_0_0;
		g_iKeySwitch_Stats[client][0][1] = x.g_iKeySwitch_Stats_0_1;
		g_iKeySwitch_Stats[client][1][0] = x.g_iKeySwitch_Stats_1_0;
		g_iKeySwitch_Stats[client][1][1] = x.g_iKeySwitch_Stats_1_1;
		g_iKeySwitch_Stats[client][2][0] = x.g_iKeySwitch_Stats_2_0;
		g_iKeySwitch_Stats[client][2][1] = x.g_iKeySwitch_Stats_2_1;

		g_bKeySwitch_IsRecorded[client][0] = x.g_bKeySwitch_IsRecorded_0;
		g_bKeySwitch_IsRecorded[client][1] = x.g_bKeySwitch_IsRecorded_1;

		g_iKeySwitch_LastRecordedTick[client] = x.g_iKeySwitch_LastRecordedTick;
		g_iIllegalTurn[client] = x.g_iIllegalTurn;
		g_iIllegalTurn_CurrentFrame[client] = x.g_iIllegalTurn_CurrentFrame;
		g_iIllegalTurn_IsTiming[client] = x.g_iIllegalTurn_IsTiming;
		g_iLastIllegalReason[client] = x.g_iLastIllegalReason;
		g_iIllegalSidemoveCount[client] = x.g_iIllegalSidemoveCount;
		g_iLastIllegalSidemoveCount[client] = x.g_iLastIllegalSidemoveCount;
		g_iLastInvalidButtonCount[client] = x.g_iLastInvalidButtonCount;
		g_iYawChangeCount[client] = x.g_iYawChangeCount;
	}

	CheckPlayerHistory(client);
}

void CheckPlayerHistory(int client)
{
    char steam_id[64];
    if (!GetClientAuthId(client, AuthId_Steam2, steam_id, sizeof(steam_id)))
        return;

    char query[256];
    Format(query, sizeof(query), 
        "SELECT avg_gain, suspicious_actions FROM player_data WHERE steam_id = '%s';",
        steam_id);

    g_hDatabase.Query(SQL_CheckPlayerHistoryCallback, query, GetClientUserId(client));
}

public void SQL_CheckPlayerHistoryCallback(Database db, DBResultSet results, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client == 0)
        return;

    if (results == null)
    {
        LogError("Query failed: %s", error);
        return;
    }

    if (results.RowCount == 0)
    {
        LogMessage("No previous data for player %L", client);
        return;
    }

    results.FetchRow();
    float avg_gain = results.FetchFloat(0);
    int suspicious_actions = results.FetchInt(1);

    if (avg_gain > 85.0 || suspicious_actions > 1000)  // these should be cvars too
    {
        LogMessage("Player %L has suspicious history: avg_gain = %.2f, suspicious_actions = %d", 
            client, avg_gain, suspicious_actions);
        // unfinished
    }
}

public void OnClientPutInServer(int client)
{
	if(IsFakeClient(client))
		return;

	SDKHook(client, SDKHook_Touch, Hook_OnTouch);

	if(g_bDhooksLoaded)
	{
		DHookEntity(g_hTeleport, false, client);
	}

	QueryForCvars(client); // not sure why so just gonna ignore it
}

public void OnClientDisconnect(int client) // this needs to be optimized, we're gonna get memory issues at some point
{
	if (GetSteamAccountID(client) != 0 && g_hPersistentData.BoolValue)
	{
		fuck_sourcemod x;
		x.accountid = GetSteamAccountID(client);

		x.g_iRealButtons = g_iRealButtons[client];
		x.g_iButtons = g_iButtons[client];
		x.g_iLastButtons = g_iButtons[client];

		x.g_iLastPressTick_0 = g_iLastPressTick[client][0];
		x.g_iLastPressTick_1 = g_iLastPressTick[client][1];
		x.g_iLastPressTick_2 = g_iLastPressTick[client][2];
		x.g_iLastPressTick_3 = g_iLastPressTick[client][3];

		x.g_iLastPressTick_Recorded_0 = g_iLastPressTick_Recorded[client][0];
		x.g_iLastPressTick_Recorded_1 = g_iLastPressTick_Recorded[client][1];
		x.g_iLastPressTick_Recorded_2 = g_iLastPressTick_Recorded[client][2];
		x.g_iLastPressTick_Recorded_3 = g_iLastPressTick_Recorded[client][3];

		x.g_iLastPressTick_Recorded_KS_0 = g_iLastPressTick_Recorded_KS[client][0];
		x.g_iLastPressTick_Recorded_KS_1 = g_iLastPressTick_Recorded_KS[client][1];
		x.g_iLastPressTick_Recorded_KS_2 = g_iLastPressTick_Recorded_KS[client][2];
		x.g_iLastPressTick_Recorded_KS_3 = g_iLastPressTick_Recorded_KS[client][3];

		x.g_iKeyPressesThisStrafe = g_iKeyPressesThisStrafe[client];

		x.g_iLastReleaseTick_0 = g_iLastReleaseTick[client][0];
		x.g_iLastReleaseTick_1 = g_iLastReleaseTick[client][1];
		x.g_iLastReleaseTick_2 = g_iLastReleaseTick[client][2];
		x.g_iLastReleaseTick_3 = g_iLastReleaseTick[client][3];

		x.g_iLastReleaseTick_Recorded_0 = g_iLastReleaseTick_Recorded[client][0];
		x.g_iLastReleaseTick_Recorded_1 = g_iLastReleaseTick_Recorded[client][1];
		x.g_iLastReleaseTick_Recorded_2 = g_iLastReleaseTick_Recorded[client][2];
		x.g_iLastReleaseTick_Recorded_3 = g_iLastReleaseTick_Recorded[client][3];

		x.g_iLastReleaseTick_Recorded_KS_0 = g_iLastReleaseTick_Recorded_KS[client][0];
		x.g_iLastReleaseTick_Recorded_KS_1 = g_iLastReleaseTick_Recorded_KS[client][1];
		x.g_iLastReleaseTick_Recorded_KS_2 = g_iLastReleaseTick_Recorded_KS[client][2];
		x.g_iLastReleaseTick_Recorded_KS_3 = g_iLastReleaseTick_Recorded_KS[client][3];

		x.g_fLastMove = g_fLastMove[client];
		x.g_iLastTurnDir = g_iLastTurnDir[client];
		x.g_iLastTurnTick = g_iLastTurnTick[client];
		x.g_iLastTurnTick_Recorded_StartStrafe = g_iLastTurnTick_Recorded_StartStrafe[client];
		x.g_iLastTurnTick_Recorded_EndStrafe = g_iLastTurnTick_Recorded_EndStrafe[client];
		x.g_iLastStopTurnTick = g_iLastStopTurnTick[client];
		x.g_bIsTurning = g_bIsTurning[client];
		x.g_iReleaseTickAtLastEndStrafe = g_iReleaseTickAtLastEndStrafe[client];
		x.g_fLastAngles = g_fLastAngles[client];
		x.g_InvalidButtonSidemoveCount = g_InvalidButtonSidemoveCount[client];
		x.g_iCmdNum = g_iCmdNum[client];
		x.g_fLastPosition = g_fLastPosition[client];
		x.g_iLastTeleportTick = g_iLastTeleportTick[client];
		x.g_fAngleDifference = g_fAngleDifference[client];
		x.g_fLastAngleDifference = g_fLastAngleDifference[client];

		x.g_strafeTick = g_strafeTick[client];
		x.g_flRawGain = g_flRawGain[client];
		x.g_bTouchesWall = g_bTouchesWall[client];
		x.g_iJump = g_iJump[client];
		x.g_iTicksOnGround = g_iTicksOnGround[client];
		x.g_iYawSpeed = g_iYawSpeed[client];
		x.g_iYawTickCount = g_iYawTickCount[client];
		x.g_iTimingTickCount = g_iTimingTickCount[client];
		x.g_iStrafesDone = g_iStrafesDone[client];
		x.g_bFirstSixJumps = g_bFirstSixJumps[client];

		x.g_iStartStrafe_CurrentFrame = g_iStartStrafe_CurrentFrame[client];

		x.g_iStartStrafe_Stats_0 = g_iStartStrafe_Stats[client][0];
		x.g_iStartStrafe_Stats_1 = g_iStartStrafe_Stats[client][1];
		x.g_iStartStrafe_Stats_2 = g_iStartStrafe_Stats[client][2];
		x.g_iStartStrafe_Stats_3 = g_iStartStrafe_Stats[client][3];
		x.g_iStartStrafe_Stats_4 = g_iStartStrafe_Stats[client][4];
		x.g_iStartStrafe_Stats_5 = g_iStartStrafe_Stats[client][5];
		x.g_iStartStrafe_Stats_6 = g_iStartStrafe_Stats[client][6];

		x.g_iStartStrafe_LastRecordedTick = g_iStartStrafe_LastRecordedTick[client];
		x.g_iStartStrafe_LastTickDifference = g_iStartStrafe_LastTickDifference[client];
		x.g_bStartStrafe_IsRecorded = g_bStartStrafe_IsRecorded[client];
		x.g_iStartStrafe_IdenticalCount = g_iStartStrafe_IdenticalCount[client];

		x.g_iEndStrafe_CurrentFrame = g_iEndStrafe_CurrentFrame[client];

		x.g_iEndStrafe_Stats_0 = g_iEndStrafe_Stats[client][0];
		x.g_iEndStrafe_Stats_1 = g_iEndStrafe_Stats[client][1];
		x.g_iEndStrafe_Stats_2 = g_iEndStrafe_Stats[client][2];
		x.g_iEndStrafe_Stats_3 = g_iEndStrafe_Stats[client][3];
		x.g_iEndStrafe_Stats_4 = g_iEndStrafe_Stats[client][4];
		x.g_iEndStrafe_Stats_5 = g_iEndStrafe_Stats[client][5];
		x.g_iEndStrafe_Stats_6 = g_iEndStrafe_Stats[client][6];

		x.g_iEndStrafe_LastRecordedTick = g_iEndStrafe_LastRecordedTick[client];
		x.g_iEndStrafe_LastTickDifference = g_iEndStrafe_LastTickDifference[client];
		x.g_bEndStrafe_IsRecorded = g_bEndStrafe_IsRecorded[client];
		x.g_iEndStrafe_IdenticalCount = g_iEndStrafe_IdenticalCount[client];
		x.g_iKeySwitch_CurrentFrame = g_iKeySwitch_CurrentFrame[client];

		x.g_iKeySwitch_Stats_0_0 = g_iKeySwitch_Stats[client][0][0];
		x.g_iKeySwitch_Stats_0_1 = g_iKeySwitch_Stats[client][0][1];
		x.g_iKeySwitch_Stats_1_0 = g_iKeySwitch_Stats[client][1][0];
		x.g_iKeySwitch_Stats_1_1 = g_iKeySwitch_Stats[client][1][1];
		x.g_iKeySwitch_Stats_2_0 = g_iKeySwitch_Stats[client][2][0];
		x.g_iKeySwitch_Stats_2_1 = g_iKeySwitch_Stats[client][2][1];

		x.g_bKeySwitch_IsRecorded_0 = g_bKeySwitch_IsRecorded[client][0];
		x.g_bKeySwitch_IsRecorded_1 = g_bKeySwitch_IsRecorded[client][1];

		x.g_iKeySwitch_LastRecordedTick = g_iKeySwitch_LastRecordedTick[client];
		x.g_iIllegalTurn = g_iIllegalTurn[client];
		x.g_iIllegalTurn_CurrentFrame = g_iIllegalTurn_CurrentFrame[client];
		x.g_iIllegalTurn_IsTiming = g_iIllegalTurn_IsTiming[client];
		x.g_iLastIllegalReason = g_iLastIllegalReason[client];
		x.g_iIllegalSidemoveCount = g_iIllegalSidemoveCount[client];
		x.g_iLastIllegalSidemoveCount = g_iLastIllegalSidemoveCount[client];
		x.g_iLastInvalidButtonCount = g_iLastInvalidButtonCount[client];
		x.g_iYawChangeCount = g_iYawChangeCount[client];

		g_aPersistentData.PushArray(x);
		UpdatePlayerData(client);
	}
}

public Action Hook_GroundFlags(int entity, const char[] PropName, int &iValue, int element)
{
	// there was old shavit stuff here before but it still has a future here
}

// this fixes client disconnects due to QueryForCvars overflowing the reliable stream during network interruption
#define MAX_CONVARS 12

enum
{
    CONVAR_YAWSPEED,
    CONVAR_YAW,
    CONVAR_FILTER,
    CONVAR_CUSTOMACCEL,
    CONVAR_CUSTOMACCEL_MAX,
    CONVAR_CUSTOMACCEL_SCALE,
    CONVAR_CUSTOMACCEL_EXPONENT,
    CONVAR_RAWINPUT,
    CONVAR_SENSITIVITY,
    CONVAR_YAWSENSITIVITY,
    CONVAR_JOYSTICK,
    CONVAR_ZOOMSENSITIVITY
};

bool g_bQueryPending[MAXPLAYERS + 1][MAX_CONVARS]; // track pending queries... 

void QueryForCvars(int client)
{
    // Always query these cvars
    if (!g_bQueryPending[client][CONVAR_YAW])
    {
        QueryClientConVar(client, "m_yaw", OnYawRetrieved);
        g_bQueryPending[client][CONVAR_YAW] = true;
    }

    if (!g_bQueryPending[client][CONVAR_SENSITIVITY])
    {
        QueryClientConVar(client, "sensitivity", OnSensitivityRetrieved);
        g_bQueryPending[client][CONVAR_SENSITIVITY] = true;
    }

    if (!g_bQueryPending[client][CONVAR_JOYSTICK])
    {
        QueryClientConVar(client, "joystick", OnJoystickRetrieved);
        g_bQueryPending[client][CONVAR_JOYSTICK] = true;
    }

    if (!g_bQueryPending[client][CONVAR_RAWINPUT])
    {
        QueryClientConVar(client, "m_rawinput", OnRawInputRetrieved);
        g_bQueryPending[client][CONVAR_RAWINPUT] = true;
    }

    if (g_Engine == Engine_CSS)
    {
        if (!g_bQueryPending[client][CONVAR_YAWSPEED])
        {
            QueryClientConVar(client, "cl_yawspeed", OnYawSpeedRetrieved);
            g_bQueryPending[client][CONVAR_YAWSPEED] = true;
        }

        if (!g_bQueryPending[client][CONVAR_ZOOMSENSITIVITY])
        {
            QueryClientConVar(client, "zoom_sensitivity_ratio", OnZoomSensitivityRetrieved);
            g_bQueryPending[client][CONVAR_ZOOMSENSITIVITY] = true;
        }
    }
    else if (g_Engine == Engine_CSGO)
    {
        if (!g_bQueryPending[client][CONVAR_ZOOMSENSITIVITY])
        {
            QueryClientConVar(client, "zoom_sensitivity_ratio_mouse", OnZoomSensitivityRetrieved);
            g_bQueryPending[client][CONVAR_ZOOMSENSITIVITY] = true;
        }
    }

    // note: m_ queries that do nothing with m_rawinput 1 are now only called if m_rawinput is 0, and are handled in the OnRawInputRetrieved callback.
    // joy_yawsensitivity is only queried if joystick is not 0 and it is handled in the OnJoystickRetrieved callback.
}

public void SimulateConVarQueryCompleted(int client, int convar)
{
    g_bQueryPending[client][convar] = false;
}

public void OnYawSpeedRetrieved(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue)
{
	g_iYawSpeed[client] = StringToFloat(cvarValue);

	if(g_iYawSpeed[client] < 0)
	{
		KickClient(client, "cl_yawspeed cannot be negative");
	}

	SimulateConVarQueryCompleted(client, CONVAR_YAWSPEED);
}

public void OnYawRetrieved(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue)
{
	float mYaw = StringToFloat(cvarValue);
	if(mYaw != g_mYaw[client])
	{
		g_mYaw[client] = mYaw;
		g_mYawChangedCount[client]++;

		if(g_mYawChangedCount[client] > 1)
		{
			PrintToAdmins("%N changed their m_yaw ConVar to %.2f", client, mYaw);
				//AnticheatLog("%L changed their m_yaw ConVar to %.2f", client, mYaw);
		}
	}

	g_mYawCheckedCount[client]++;
	SimulateConVarQueryCompleted(client, CONVAR_YAW);
}

public void OnFilterRetrieved(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue)
{
	bool mFilter = (0.0 <= StringToFloat(cvarValue) < 1.0)?false:true;
	if(mFilter != g_mFilter[client])
	{
		g_mFilterChangedCount[client]++;
		g_mFilter[client] = mFilter;

		if(g_mFilterChangedCount[client] > 1)
		{
			PrintToAdmins("%N changed their m_filter ConVar to %d", client, mFilter);
				//AnticheatLog("%L changed their m_filter ConVar to %d", client, mFilter);
		}
	}

	g_mFilterCheckedCount[client]++;
	SimulateConVarQueryCompleted(client, CONVAR_FILTER);
}

public void OnCustomAccelRetrieved(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue)
{
	int mCustomAccel = StringToInt(cvarValue);

	if(mCustomAccel != g_mCustomAccel[client])
	{
		g_mCustomAccel[client] = mCustomAccel;
		g_mCustomAccelChangedCount[client]++;

		if(g_mCustomAccelChangedCount[client] > 1)
		{
			PrintToAdmins("%N changed their m_customaccel ConVar to %d", client, mCustomAccel);
				//AnticheatLog("%L changed their m_customaccel ConVar to %d", client, mCustomAccel);
		}
	}

	g_mCustomAccelCheckedCount[client]++;
	SimulateConVarQueryCompleted(client, CONVAR_CUSTOMACCEL);
}

public void OnCustomAccelMaxRetrieved(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue)
{
	float mCustomAccelMax = StringToFloat(cvarValue);

	if(mCustomAccelMax != g_mCustomAccelMax[client])
	{
		g_mCustomAccelMax[client] = mCustomAccelMax;
		g_mCustomAccelMaxChangedCount[client]++;

		if(g_mCustomAccelMaxChangedCount[client] > 1)
		{
			PrintToAdmins("%N changed their m_customaccel_max ConVar to %f", client, mCustomAccelMax);
		}
	}

	g_mCustomAccelMaxCheckedCount[client]++;
	SimulateConVarQueryCompleted(client, CONVAR_CUSTOMACCEL_MAX);
}

public void OnCustomAccelScaleRetrieved(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue)
{
	float mCustomAccelScale = StringToFloat(cvarValue);

	if(mCustomAccelScale != g_mCustomAccelScale[client])
	{
		g_mCustomAccelScale[client] = mCustomAccelScale;
		g_mCustomAccelScaleChangedCount[client]++;

		if(g_mCustomAccelScaleChangedCount[client] > 1)
		{
			PrintToAdmins("%N changed their m_customaccel_scale ConVar to %f", client, mCustomAccelScale);
				//AnticheatLog("%L changed their m_customaccel ConVar to %d", client, mCustomAccel);
		}
	}

	g_mCustomAccelScaleCheckedCount[client]++;
	SimulateConVarQueryCompleted(client, CONVAR_CUSTOMACCEL_SCALE);
}

public void OnCustomAccelExRetrieved(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue)
{
	float mCustomAccelExponent = StringToFloat(cvarValue);

	if(mCustomAccelExponent != g_mCustomAccelExponent[client])
	{
		g_mCustomAccelExponent[client] = mCustomAccelExponent;
		g_mCustomAccelExponentChangedCount[client]++;

		if(g_mCustomAccelExponentChangedCount[client] > 1)
		{
			PrintToAdmins("%N changed their m_customaccel_exponent ConVar to %f", client, mCustomAccelExponent);
				//AnticheatLog("%L changed their m_customaccel ConVar to %d", client, mCustomAccel);
		}
	}

	g_mCustomAccelExponentCheckedCount[client]++;
	SimulateConVarQueryCompleted(client, CONVAR_CUSTOMACCEL_EXPONENT);
}

public void OnRawInputRetrieved(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue)
{
    bool mRawInput = (0.0 <= StringToFloat(cvarValue) < 1.0) ? false : true;
    if (mRawInput != g_mRawInput[client])
    {
        g_mRawInputChangedCount[client]++;
        g_mRawInput[client] = mRawInput;

        if (g_mRawInputChangedCount[client] > 1)
        {
            PrintToAdmins("%N changed their m_rawinput ConVar to %d", client, mRawInput);
        }
    }

    g_mRawInputCheckedCount[client]++;
    g_bQueryPending[client][CONVAR_RAWINPUT] = false;

    // if m_rawinput is 0, query additional cvars
    if (!mRawInput)
    {
        if (!g_bQueryPending[client][CONVAR_CUSTOMACCEL])
        {
            QueryClientConVar(client, "m_customaccel", OnCustomAccelRetrieved);
            g_bQueryPending[client][CONVAR_CUSTOMACCEL] = true;
        }
        if (!g_bQueryPending[client][CONVAR_CUSTOMACCEL_MAX])
        {
            QueryClientConVar(client, "m_customaccel_max", OnCustomAccelMaxRetrieved);
            g_bQueryPending[client][CONVAR_CUSTOMACCEL_MAX] = true;
        }
        if (!g_bQueryPending[client][CONVAR_FILTER])
        {
            QueryClientConVar(client, "m_filter", OnFilterRetrieved);
            g_bQueryPending[client][CONVAR_FILTER] = true;
        }
        if (!g_bQueryPending[client][CONVAR_CUSTOMACCEL_SCALE])
        {
            QueryClientConVar(client, "m_customaccel_scale", OnCustomAccelScaleRetrieved);
            g_bQueryPending[client][CONVAR_CUSTOMACCEL_SCALE] = true;
        }
        if (!g_bQueryPending[client][CONVAR_CUSTOMACCEL_EXPONENT])
        {
            QueryClientConVar(client, "m_customaccel_exponent", OnCustomAccelExRetrieved);
            g_bQueryPending[client][CONVAR_CUSTOMACCEL_EXPONENT] = true;
        }
    }
}

public void OnSensitivityRetrieved(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue)
{
	float sensitivity = StringToFloat(cvarValue);
	if(sensitivity != g_Sensitivity[client])
	{
		g_Sensitivity[client] = sensitivity;
		g_SensitivityChangedCount[client]++;

		if(g_SensitivityChangedCount[client] > 1)
		{
			PrintToAdmins("%N changed their sensitivity ConVar to %.2f", client, sensitivity);
				//AnticheatLog("%L changed their sensitivity ConVar to %.2f", client, sensitivity);
		}
	}

	g_SensitivityCheckedCount[client]++;
	SimulateConVarQueryCompleted(client, CONVAR_SENSITIVITY);
}

public void OnYawSensitivityRetrieved(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue)
{
	float sensitivity = StringToFloat(cvarValue);
	if(sensitivity != g_JoySensitivity[client])
	{
		g_JoySensitivity[client] = sensitivity;
		g_JoySensitivityChangedCount[client]++;

		if(g_JoySensitivityChangedCount[client] > 1)
		{
			PrintToAdmins("%N changed their joy_yawsensitivity ConVar to %.2f", client, sensitivity);
				//AnticheatLog("%L changed their joy_yawsensitivity ConVar to %.2f", client, sensitivity);
		}
	}

	g_JoySensitivityCheckedCount[client]++;
	SimulateConVarQueryCompleted(client, CONVAR_YAWSENSITIVITY);
}

public void OnZoomSensitivityRetrieved(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue)
{
	float sensitivity = StringToFloat(cvarValue);
	if(sensitivity != g_ZoomSensitivity[client])
	{
		g_ZoomSensitivity[client] = sensitivity;
		g_ZoomSensitivityChangedCount[client]++;

		if(g_ZoomSensitivityChangedCount[client] > 1)
		{
			PrintToAdmins("%N changed their %s ConVar to %.2f", client, cvarName, sensitivity);
				//AnticheatLog("%L changed their joy_yawsensitivity ConVar to %.2f", client, sensitivity);
		}
	}

	g_ZoomSensitivityCheckedCount[client]++;
	SimulateConVarQueryCompleted(client, CONVAR_ZOOMSENSITIVITY);
}

public void OnJoystickRetrieved(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue)
{
    bool joyStick = (0.0 <= StringToFloat(cvarValue) < 1.0) ? false : true;
    if (joyStick != g_JoyStick[client])
    {
        g_JoyStickChangedCount[client]++;
        g_JoyStick[client] = joyStick;

        if (g_JoyStickChangedCount[client] > 1)
        {
            PrintToAdmins("%N changed their joystick ConVar to %d", client, joyStick);
        }
    }

    g_JoyStickCheckedCount[client]++;
    g_bQueryPending[client][CONVAR_JOYSTICK] = false;

    // if joystick is 1, query joy_yawsensitivity
    if (joyStick)
    {
        if (!g_bQueryPending[client][CONVAR_YAWSENSITIVITY])
        {
            QueryClientConVar(client, "joy_yawsensitivity", OnYawSensitivityRetrieved);
            g_bQueryPending[client][CONVAR_YAWSENSITIVITY] = true;
        }
    }
}


public Action Hook_OnTouch(int client, int entity) // this is basically useless right now but i have a great idea
{
	if(entity == 0)
	{
		g_bTouchesWall[client] = true;
	}

	char sClassname[64];
	GetEntityClassname(entity, sClassname, sizeof(sClassname));
	if(StrEqual(sClassname, "func_rotating"))
	{
		g_bTouchesFuncRotating[client] = true;
	}

}

public Action Bash_Stats(int client, int args) // could use permission checks
{
	if(args == 0)
	{
		int target;
		if(IsPlayerAlive(client))
		{
			target = client;
		}
		else
		{
			target = GetEntPropEnt(client, Prop_Send, "m_hObserverTarget");
		}

		if(0 < target <= MaxClients)
		{
			ShowBashStats(client, GetClientUserId(target));
		}
	}
	else
	{
		char sArg[MAX_NAME_LENGTH];
		GetCmdArgString(sArg, MAX_NAME_LENGTH);

		if(sArg[0] == '#')
		{
			ReplaceString(sArg, MAX_NAME_LENGTH, "#", "", true);
			int target = GetClientOfUserId(StringToInt(sArg, 10));
			if(target)
			{
				ShowBashStats(client, GetClientUserId(target));
			}
			else
			{
				ReplyToCommand(client, "[BASH] No player with userid '%s'.", sArg);
			}
		}

		char sName[MAX_NAME_LENGTH];
		bool bFoundTarget;
		for(int target = 1; target <= MaxClients; target++)
		{
			if(IsClientInGame(target))
			{
				GetClientName(target, sName, MAX_NAME_LENGTH);
				if(StrContains(sName, sArg, false) != -1)
				{
					bFoundTarget = true;
					ShowBashStats(client, GetClientUserId(target));
				}
			}
		}

		if(!bFoundTarget)
		{
			ReplyToCommand(client, "[BASH] No player found with '%s' in their name.", sArg);
		}
	}

	return Plugin_Handled;
}

public Action Bash_AdminMode(int client, int args) // same thing as above
{
	if(g_bAdminMode[client])
	{
		g_bAdminMode[client] = !g_bAdminMode[client];
		ReplyToCommand(client, "[BASH] You are no longer in admin mode.");
	} else {
		g_bAdminMode[client] = !g_bAdminMode[client]
		ReplyToCommand(client, "[BASH] You are now in admin mode.");
	}
	return Plugin_Handled;
}

public Action Bash_Test(int client, int args) // here too
{
	if (client == 0)
	{
		for (int i = 1; i<= MaxClients; i++)
		{
			if (IsClientConnected(i) && IsClientInGame(i))
			{
				client = i;
				break;
			}
		}
	}

	if (client == 0)
	{
		PrintToServer("No client to use for test log... :|");
	}
	else
	{
		AnticheatLog(client, "bash2_test log. plz ignore :)");
	}

	return Plugin_Handled;
}

void ShowBashStats(int client, int userid) // definitely need to add pagination here at some point
{
	int target = GetClientOfUserId(userid);
	if(target == 0)
	{
		PrintToChat(client, "[BASH] Selected player no longer ingame.");
		return;
	}

	g_iTarget[client] = userid;
	Menu menu = new Menu(BashStats_MainMenu);
	char sName[MAX_NAME_LENGTH];
	GetClientName(target, sName, sizeof(sName));
	menu.SetTitle("[BASH] - Select stats for %N", target);

	menu.AddItem("start",      "Start Strafe (Original)");
	menu.AddItem("end",        "End Strafe");
	menu.AddItem("keys",       "Key Switch");

	char sGain[32];
	FormatEx(sGain, 32, "Current gains: %.2f", GetGainPercent(target));
	menu.AddItem("gain", sGain);
	/*if(IsBlacky(client))
	{
		menu.AddItem("man1",       "Manual Test (MOTD)");
		menu.AddItem("man2",       "Manual Test (Angle)");
		menu.AddItem("flags",      "Player flags", ITEMDRAW_DISABLED);
	}*/

	menu.Display(client, MENU_TIME_FOREVER);
}

public int BashStats_MainMenu(Menu menu, MenuAction action, int param1, int param2) // same as above
{
	if(action == MenuAction_Select)
	{
		char sInfo[32];
		menu.GetItem(param2, sInfo, sizeof(sInfo));

		if(StrEqual(sInfo, "start"))
		{
			ShowBashStats_StartStrafes(param1);
		}
		else if(StrEqual(sInfo, "end"))
		{
			ShowBashStats_EndStrafes(param1);
		}
		else if(StrEqual(sInfo, "keys"))
		{
			ShowBashStats_KeySwitches(param1);
		}
		else if(StrEqual(sInfo, "gain"))
		{
			ShowBashStats(param1, g_iTarget[param1]);
		}
		else if(StrEqual(sInfo, "man1"))
		{
			PerformMOTDTest(param1);
		}
		else if(StrEqual(sInfo, "man2"))
		{
			PerformAngleTest(param1);
		}
		else if(StrEqual(sInfo, "flags"))
		{

		}
	}

	if (action & MenuAction_End)
	{
		delete menu;
	}
}

void PerformMOTDTest(int client)
{
	int target = GetClientOfUserId(g_iTarget[client]);
	if(target == 0)
	{
		return;
	}

	//void ShowVGUIPanel(int client, const char[] name, Handle Kv, bool show)
	//MotdChanger_SendClientMotd(client, "Welcome", "text", "Welcome to nope!");
	g_bMOTDTest[target] = true;
	if(g_Engine == Engine_CSGO)
	{
		ShowMOTDPanel(target, "Welcome", "http://chucktesta.com/welcome.html", MOTDPANEL_TYPE_URL);
	}
	else if(g_Engine == Engine_CSS)
	{
		ShowMOTDPanel(target, "Welcome", "http://chucktesta.com/", MOTDPANEL_TYPE_URL);
	}
}

stock void PerformAngleTest(int client)
{
    int target = GetClientOfUserId(g_iTarget[client]);
    if(target == 0)
    {
        return;
    }

    float startAngles[3];
    GetClientEyeAngles(target, startAngles);

    // store the starting angles
    g_MOTDTestAngles[target] = startAngles;

    // create a timer to check the angles after a short delay
    CreateTimer(0.1, Timer_CheckAngleTest, GetClientUserId(target));
}

public Action Timer_CheckAngleTest(Handle timer, any data)
{
    int target = GetClientOfUserId(data);
    if(target == 0)
    {
        return Plugin_Stop;
    }

    float currentAngles[3];
    GetClientEyeAngles(target, currentAngles);

    // calculate the difference between starting and current angles
    float angleDifference = FloatAbs(g_MOTDTestAngles[target][1] - currentAngles[1]);

    // check if the angle difference is suspiciously large
    if(angleDifference > 50.0)
    {
        AnticheatLog(target, "Failed manual angle test. Angle difference: %.2f", angleDifference);
        g_iLastIllegalReason[target] |= DR_FailedManualAngleTest;
    }

    return Plugin_Stop;
}

void ShowBashStats_StartStrafes(int client)
{
	int target = GetClientOfUserId(g_iTarget[client]);
	if(target == 0)
	{
		PrintToChat(client, "[BASH] Selected player no longer ingame.");
		return;
	}

	int array[MAX_FRAMES];
	int buttons[4];
	int size;
	for(int idx; idx < MAX_FRAMES; idx++)
	{
		if(g_bStartStrafe_IsRecorded[target][idx] == true)
		{
			array[idx] = g_iStartStrafe_Stats[target][StrafeData_Difference][idx];
			buttons[g_iStartStrafe_Stats[target][StrafeData_Button][idx]]++;
			size++;
		}
	}

	if(size == 0)
	{
		PrintToChat(client, "[BASH] Player '%N' has no start strafe stats.", target);
	}
	float startStrafeMean = GetAverage(array, size);
	float startStrafeSD   = StandardDeviation(array, size, startStrafeMean);

	Menu menu = new Menu(BashStats_StartStrafesMenu);
	menu.SetTitle("[BASH] Start Strafe stats for %N\nAverage: %.2f | Deviation: %.2f\nA: %d, D: %d, W: %d, S: %d\n ",
		target, startStrafeMean, startStrafeSD,
		buttons[2], buttons[3], buttons[0], buttons[1]);

	char sDisplay[128];
	for(int idx; idx < size; idx++)
	{
		Format(sDisplay, sizeof(sDisplay), "%s%d ", sDisplay, array[idx]);

		if((idx + 1) % 10 == 0  || size - idx == 1)
		{
			menu.AddItem("", sDisplay, ITEMDRAW_DISABLED);
			FormatEx(sDisplay, sizeof(sDisplay), "");
		}
	}

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int BashStats_StartStrafesMenu(Menu menu, MenuAction action, int param1, int param2) // i'll do these at some point
{
	/*
	if(action == MenuAction_Select)
	{

	}
	*/
	if(action == MenuAction_Cancel)
	{
		if(param2 == MenuCancel_ExitBack)
			ShowBashStats(param1, g_iTarget[param1]);
	}

	if (action & MenuAction_End)
	{
		delete menu;
	}
}

void ShowBashStats_EndStrafes(int client)
{
	int target = GetClientOfUserId(g_iTarget[client]);
	if(target == 0)
	{
		PrintToChat(client, "[BASH] Selected player no longer ingame.");
		return;
	}

	int array[MAX_FRAMES];
	int buttons[4];
	int size;
	for(int idx; idx < MAX_FRAMES; idx++)
	{
		if(g_bEndStrafe_IsRecorded[target][idx] == true)
		{
			array[idx] = g_iEndStrafe_Stats[target][StrafeData_Difference][idx];
			buttons[g_iEndStrafe_Stats[target][StrafeData_Button][idx]]++;
			size++;
		}
	}

	if(size == 0)
	{
		PrintToChat(client, "[BASH] Player '%N' has no end strafe stats.", target);
	}

	float mean = GetAverage(array, size);
	float sd   = StandardDeviation(array, size, mean);

	Menu menu = new Menu(BashStats_EndStrafesMenu);
	menu.SetTitle("[BASH] End Strafe stats for %N\nAverage: %.2f | Deviation: %.2f\nA: %d, D: %d, W: %d, S: %d\n ",
		target, mean, sd,
		buttons[2], buttons[3], buttons[0], buttons[1]);

	char sDisplay[128];
	for(int idx; idx < size; idx++)
	{
		Format(sDisplay, sizeof(sDisplay), "%s%d ", sDisplay, array[idx]);

		if((idx + 1) % 10 == 0  || (size - idx == 1))
		{
			menu.AddItem("", sDisplay, ITEMDRAW_DISABLED);
			FormatEx(sDisplay, sizeof(sDisplay), "");
		}
	}

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int BashStats_EndStrafesMenu(Menu menu, MenuAction action, int param1, int param2) // i swear
{
	/*
	if(action == MenuAction_Select)
	{

	}
	*/
	if(action == MenuAction_Cancel)
	{
		if(param2 == MenuCancel_ExitBack)
			ShowBashStats(param1, g_iTarget[param1]);
	}

	if (action & MenuAction_End)
	{
		delete menu;
	}
}

void ShowBashStats_KeySwitches(int client)
{
	int target = GetClientOfUserId(g_iTarget[client]);
	if(target == 0)
	{
		PrintToChat(client, "[BASH] Selected player no longer ingame.");
		return;
	}

	Menu menu = new Menu(BashStats_KeySwitchesMenu);
	menu.SetTitle("[BASH] Select key switch type");
	menu.AddItem("move", "Movement");
	menu.AddItem("key",  "Buttons");
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int BashStats_KeySwitchesMenu(Menu menu, MenuAction action, int param1, int param2)
{
	if(action & MenuAction_Select)
	{
		char sInfo[32];
		menu.GetItem(param2, sInfo, sizeof(sInfo));

		if(StrEqual(sInfo, "move"))
		{
			ShowBashStats_KeySwitches_Move(param1);
		}
		else if(StrEqual(sInfo, "key"))
		{
			ShowBashStats_KeySwitches_Keys(param1);
		}
	}
	if(action == MenuAction_Cancel)
	{
		if(param2 == MenuCancel_ExitBack)
			ShowBashStats(param1, g_iTarget[param1]);
	}

	if (action & MenuAction_End)
	{
		delete menu;
	}
}

void ShowBashStats_KeySwitches_Move(int client)
{
	int target = GetClientOfUserId(g_iTarget[client]);
	if(target == 0)
	{
		PrintToChat(client, "[BASH] Selected player no longer ingame.");
		return;
	}

	int array[MAX_FRAMES_KEYSWITCH];
	int size;
	for(int idx; idx < MAX_FRAMES_KEYSWITCH; idx++)
	{
		if(g_bKeySwitch_IsRecorded[target][BT_Move][idx] == true)
		{
			array[idx] = g_iKeySwitch_Stats[target][KeySwitchData_Difference][BT_Move][idx];
			size++;
		}
	}
	float mean = GetAverage(array, size);
	float sd   = StandardDeviation(array, size, mean);

	Menu menu = new Menu(BashStats_KeySwitchesMenu_Move);
	menu.SetTitle("[BASH] Sidemove Switch stats for %N\nAverage: %.2f | Deviation: %.2f\n ", target, mean, sd);

	char sDisplay[128];
	for(int idx; idx < size; idx++)
	{
		Format(sDisplay, sizeof(sDisplay), "%s%d ", sDisplay, array[idx]);

		if((idx + 1) % 10 == 0  || (size - idx == 1))
		{
			menu.AddItem("", sDisplay, ITEMDRAW_DISABLED);
			FormatEx(sDisplay, sizeof(sDisplay), "");
		}
	}

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

void ShowBashStats_KeySwitches_Keys(int client)
{
	int target = GetClientOfUserId(g_iTarget[client]);
	if(target == 0)
	{
		PrintToChat(client, "[BASH] Selected player no longer ingame.");
		return;
	}

	int array[MAX_FRAMES_KEYSWITCH];
	int size, positiveCount;
	for(int idx; idx < MAX_FRAMES_KEYSWITCH; idx++)
	{
		if(g_bKeySwitch_IsRecorded[target][BT_Key][idx] == true)
		{
			array[idx] = g_iKeySwitch_Stats[target][KeySwitchData_Difference][BT_Key][idx];
			size++;

			if(g_iKeySwitch_Stats[target][KeySwitchData_Difference][BT_Key][idx] >= 0)
			{
				positiveCount++;
			}
		}
	}

	float mean = GetAverage(array, size);
	float sd   = StandardDeviation(array, size, mean);
	float pctPositive = float(positiveCount) / float(size);
	Menu menu = new Menu(BashStats_KeySwitchesMenu_Move);
	menu.SetTitle("[BASH] Key Switch stats for %N\nAverage: %.2f | Deviation: %.2f | Positive: %.2f\n ", target, mean, sd, pctPositive);

	char sDisplay[128];
	for(int idx; idx < size; idx++)
	{
		Format(sDisplay, sizeof(sDisplay), "%s%d ", sDisplay, array[idx]);

		if((idx + 1) % 10 == 0  || (size - idx == 1))
		{
			menu.AddItem("", sDisplay, ITEMDRAW_DISABLED);
			FormatEx(sDisplay, sizeof(sDisplay), "");
		}
	}

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int BashStats_KeySwitchesMenu_Move(Menu menu, MenuAction action, int param1, int param2) // todo
{
	/*
	if(action == MenuAction_Select)
	{

	}
	*/
	if(action == MenuAction_Cancel)
	{
		if(param2 == MenuCancel_ExitBack)
			ShowBashStats_KeySwitches(param1);
	}

	if (action & MenuAction_End)
	{
		delete menu;
	}
}

float StandardDeviation(int[] array, int size, float mean, bool countZeroes = true)
{
	float sd;

	for(int idx; idx < size; idx++)
	{
		if(countZeroes || array[idx] != 0)
		{
			sd += Pow(float(array[idx]) - mean, 2.0);
		}
	}

	return SquareRoot(sd/size);
}

float GetAverage(int[] array, int size, bool countZeroes = true)
{
	int total;

	for(int idx; idx < size; idx++)
	{
		if(countZeroes || array[idx] != 0)
		{
			total += array[idx];
		}

	}

	float flTotal = float(total) / float(size);
	return flTotal;
}

int g_iRunCmdsPerSecond[MAXPLAYERS + 1];
int g_iBadSeconds[MAXPLAYERS + 1];
float g_fLastCheckTime[MAXPLAYERS + 1];
MoveType g_mLastMoveType[MAXPLAYERS + 1];

// not gonna bother with this one til i finish the rest of my to do list
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	if(!IsFakeClient(client) && IsPlayerAlive(client))
	{
		g_iRealButtons[client] = buttons;
		// Update all information this tick
		bool bCheck = true;

		UpdateButtons(client, vel, buttons);
		UpdateAngles(client, angles);

		if(bCheck == true)
		{
			if(g_bCheckedYet[client] == false)
			{
				g_bCheckedYet[client] = true;
				g_fLastCheckTime[client] = GetEngineTime();
			}

			if(GetEntityMoveType(client) != MOVETYPE_NONE)
			{
				g_mLastMoveType[client] = GetEntityMoveType(client);
			}

			float tickRate = 1.0 / GetTickInterval();
			g_iRunCmdsPerSecond[client]++;
			if(GetEngineTime() - g_fLastCheckTime[client] >= 1.0)
			{
				if(float(g_iRunCmdsPerSecond[client]) / tickRate <= 0.95)
				{
					if(++g_iBadSeconds[client] >= 3)
					{
						//PrintToAdmins("%N has had %d bad seconds", client, g_iBadSeconds[client]);
						SetEntityMoveType(client, MOVETYPE_NONE);
					}
				}
				else
				{
					if(GetEntityMoveType(client) == MOVETYPE_NONE)
					{
						SetEntityMoveType(client, g_mLastMoveType[client]);
					}
					g_iBadSeconds[client] = 0;
				}

				g_fLastCheckTime[client] = GetEngineTime();
				g_iRunCmdsPerSecond[client] = 0;
			}
		}

		if(!g_bDhooksLoaded) CheckForTeleport(client);
		CheckForEndKey(client);
		CheckForTurn(client);
		CheckForStartKey(client);

		// After we have all the information we can get, do stuff with it
		if(!(GetEntityFlags(client) & (FL_ONGROUND|FL_INWATER)) && GetEntityMoveType(client) == MOVETYPE_WALK && bCheck)
		{
			for(int idx; idx < 4; idx++)
			{
				if(g_iLastReleaseTick[client][idx][BT_Move] == g_iCmdNum[client])
				{
					ClientReleasedKey(client, idx, BT_Move);
				}

				if(g_iLastReleaseTick[client][idx][BT_Key] == g_iCmdNum[client])
				{
					ClientReleasedKey(client, idx, BT_Key);
				}
			}

			if(g_iLastTurnTick[client] == g_iCmdNum[client])
			{
				ClientTurned(client, g_iLastTurnDir[client]);
			}

			if(g_iLastStopTurnTick[client] == g_iCmdNum[client])
			{
				ClientStoppedTurning(client);
			}

			for(int idx; idx < 4; idx++)
			{
				if(g_iLastPressTick[client][idx][BT_Move] == g_iCmdNum[client])
				{
					ClientPressedKey(client, idx, BT_Move);
				}

				if(g_iLastPressTick[client][idx][BT_Key] == g_iCmdNum[client])
				{
					ClientPressedKey(client, idx, BT_Key);
				}
			}
		}

		if(bCheck)
		{
			CheckForIllegalMovement(client, vel, buttons);
			CheckForIllegalTurning(client, vel);
			UpdateGains(client, vel, angles, buttons);
		}

		g_fLastMove[client][0]   = vel[0];
		g_fLastMove[client][1]   = vel[1];
		g_fLastMove[client][2]   = vel[2];
		g_fLastAngles[client][0] = angles[0];
		g_fLastAngles[client][1] = angles[1];
		g_fLastAngles[client][2] = angles[2];
		GetClientAbsOrigin(client, g_fLastPosition[client]);
		g_fLastAngleDifference[client][0] = g_fAngleDifference[client][0];
		g_fLastAngleDifference[client][1] = g_fAngleDifference[client][1];
		g_iCmdNum[client]++;
		g_bTouchesFuncRotating[client] = false;
		g_bTouchesWall[client] = false;

		if (cmdnum % 10000 == 0)  // update every 1000 commands 
		{
			UpdatePlayerData(client);
		}
	}

	int tickInterval = RoundToNearest(60.0 / GetTickInterval()); // this is an intentional bug so people won't immediately start using an unfinished anticheat
	if (GetGameTickCount() % tickInterval == 0)  // process batch approximately every ? seconds (figure out why this is a bad idea)
	{
		ProcessBatch();
	}
}

int g_iIllegalYawCount[MAXPLAYERS + 1];
int g_iPlusLeftCount[MAXPLAYERS + 1];

/* float MAX(float a, float b)
{
	return (a > b)?a:b;
} */

// work in progress revamp

/* public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
    if(!IsFakeClient(client) && IsPlayerAlive(client))
    {
        g_iRealButtons[client] = buttons;
        
        // update all information this tick
        UpdateButtons(client, vel, buttons);
        UpdateAngles(client, angles);

        // perform checks only if the player is in a valid state for movement analysis
        if(!(GetEntityFlags(client) & (FL_ONGROUND|FL_INWATER)) && GetEntityMoveType(client) == MOVETYPE_WALK)
        {
            // check for teleports
            if(!g_bDhooksLoaded) CheckForTeleport(client);

            // process key presses and releases
            ProcessKeyEvents(client);

            // check for illegal turning
            CheckForIllegalTurning(client, vel);

            // check for illegal movement
            CheckForIllegalMovement(client, vel, buttons);

            // update gains
            UpdateGains(client, vel, angles, buttons);
        }

        // update last known values
        UpdateLastKnownValues(client, vel, angles);

        // increment command number
        g_iCmdNum[client]++;

        // reset touch flags
        g_bTouchesFuncRotating[client] = false;
        g_bTouchesWall[client] = false;

        // periodically update player data
        if (cmdnum % 10000 == 0)
        {
            UpdatePlayerData(client);
        }
    }

    // process batch approximately every second
    int tickInterval = RoundToNearest(60.0 / GetTickInterval());
    if (GetGameTickCount() % tickInterval == 0)
    {
        ProcessBatch();
    }

    return Plugin_Continue;
}

void ProcessKeyEvents(int client)
{
    for(int idx; idx < 4; idx++)
    {
        if(g_iLastReleaseTick[client][idx][BT_Move] == g_iCmdNum[client])
        {
            ClientReleasedKey(client, idx, BT_Move);
        }

        if(g_iLastReleaseTick[client][idx][BT_Key] == g_iCmdNum[client])
        {
            ClientReleasedKey(client, idx, BT_Key);
        }

        if(g_iLastPressTick[client][idx][BT_Move] == g_iCmdNum[client])
        {
            ClientPressedKey(client, idx, BT_Move);
        }

        if(g_iLastPressTick[client][idx][BT_Key] == g_iCmdNum[client])
        {
            ClientPressedKey(client, idx, BT_Key);
        }
    }

    if(g_iLastTurnTick[client] == g_iCmdNum[client])
    {
        ClientTurned(client, g_iLastTurnDir[client]);
    }

    if(g_iLastStopTurnTick[client] == g_iCmdNum[client])
    {
        ClientStoppedTurning(client);
    }
}

void UpdateLastKnownValues(int client, float vel[3], float angles[3])
{
    g_fLastMove[client][0]   = vel[0];
    g_fLastMove[client][1]   = vel[1];
    g_fLastMove[client][2]   = vel[2];
    g_fLastAngles[client][0] = angles[0];
    g_fLastAngles[client][1] = angles[1];
    g_fLastAngles[client][2] = angles[2];
    GetClientAbsOrigin(client, g_fLastPosition[client]);
    g_fLastAngleDifference[client][0] = g_fAngleDifference[client][0];
    g_fLastAngleDifference[client][1] = g_fAngleDifference[client][1];
}
*/

// ------------------- TURNING ---------------
#define TURN_HISTORY_SIZE 50
#define MOVE_HISTORY_SIZE 50
#define ILLEGAL_TURN_THRESHOLD 0.8
#define SUSPICIOUS_TURN_THRESHOLD 0.6

float g_fTurnHistory[MAXPLAYERS + 1][TURN_HISTORY_SIZE];
int g_iTurnHistoryIndex[MAXPLAYERS + 1];
float g_fSideMoveHistory[MAXPLAYERS + 1][MOVE_HISTORY_SIZE];
float g_fForwardMoveHistory[MAXPLAYERS + 1][MOVE_HISTORY_SIZE];
int g_iMoveHistoryIndex[MAXPLAYERS + 1];
int g_iPreciseMovementCount[MAXPLAYERS + 1];
int g_iIllegalTurnCount[MAXPLAYERS + 1];

void CheckForIllegalTurning(int client, float vel[3])
{

	if (g_bSevereLatgSpike)
    {
        return; // skip this check during severe lag spikes
    }

	// this is for lag compensation, unused currently
	float adjustedTurnThreshold = g_cvIllegalTurnThreshold.FloatValue * g_fNormalThresholdMultiplier;

    float currentTurn = g_fAngleDifference[client][1];
    UpdateTurnHistory(client, currentTurn);
    UpdateMoveHistory(client, vel[0], vel[1]);

    if (GetClientButtons(client) & (IN_LEFT|IN_RIGHT))
    {
        g_iPlusLeftCount[client]++;
    }

    if (g_iCmdNum[client] % 100 == 0)
    {
        AnalyzeTurningBehavior(client);
    }    

    if (FloatAbs(currentTurn) < 0.01 || !IsValidTurnCheck(client))
    {
        return;
    }

    if (IsPhysicallyImpossibleTurn(client, currentTurn))
    {
        g_iIllegalYawCount[client]++;
        IncrementIllegalTurnCount(client);
        
        AnticheatLog(client, "Physically impossible turn detected (Turn: %.2f, MaxTurnRate: %.2f)", 
            currentTurn, CalculateMaxTurnRate(client));
    }

    CheckPreciseTurning(client, currentTurn);
}

void AnalyzeTurningBehavior(int client)
{
    float suspicionScore = CalculateTurningSuspicionScore(client);
    float consistencyScore = CalculateMoveConsistency(client);
    float alternationScore = CalculateMoveAlternation(client);
    bool hasImpossibleSequence = CheckForImpossibleSequences(client);

    if (suspicionScore > ILLEGAL_TURN_THRESHOLD)
    {
        AnticheatLog(client, "Illegal turning detected (Score: %.2f, m_yaw: %f, sens: %f, m_customaccel: %d, Joystick: %d)", 
            suspicionScore, g_mYaw[client], g_Sensitivity[client], g_mCustomAccel[client], g_JoyStick[client]);
        
        if (g_hAutoban.BoolValue)
        {
            AutoBanPlayer(client);
        }
    }
    else if (suspicionScore > SUSPICIOUS_TURN_THRESHOLD)
    {
		// todo
        // AnticheatLog(client, "Suspicious turning detected (Score: %.2f)", suspicionScore);
    }

    if (consistencyScore > g_cvConsistencyThreshold.FloatValue)
    {
		// todo
        // AnticheatLog(client, "Suspiciously consistent movement detected (Score: %.2f)", consistencyScore);
    }

    if (alternationScore > g_cvAlternationThreshold.FloatValue)
    {
		// todo
        // AnticheatLog(client, "Suspiciously perfect movement alternation detected (Score: %.2f)", alternationScore);
    }

    if (hasImpossibleSequence)
    {
		// todo
        // AnticheatLog(client, "Impossible movement sequence detected");
    }

    g_iIllegalYawCount[client] = 0;
    g_iPlusLeftCount[client] = 0;
}

bool IsValidTurnCheck(int client)
{
    return (g_mCustomAccelCheckedCount[client] > 0 && g_mFilterCheckedCount[client] > 0 && 
            g_mYawCheckedCount[client] > 0 && g_SensitivityCheckedCount[client] > 0 &&
            g_iCmdNum[client] - g_iLastTeleportTick[client] >= 100 &&
            FloatAbs(g_fAngleDifference[client][1]) <= 20.0 &&
            FloatAbs(g_Sensitivity[client] * g_mYaw[client]) <= 0.8 &&
            GetEntProp(client, Prop_Send, "m_iFOVStart") == 90 &&
            !g_bTouchesFuncRotating[client] &&
            g_iIllegalSidemoveCount[client] == 0);
}

bool IsPhysicallyImpossibleTurn(int client, float currentTurn)
{
    float maxTurnRate = CalculateMaxTurnRate(client);
    float airAcceleration = GetConVarFloat(FindConVar("sv_airaccelerate"));
    float tickInterval = GetTickInterval();

    float maxPossibleTurn = maxTurnRate * tickInterval * (1.0 + airAcceleration * tickInterval);

    if (FloatAbs(currentTurn) > maxPossibleTurn)
    {
        return true;
    }

    float velocity[3];
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", velocity);
    float speed = GetVectorLength(velocity);

    float maxTurnAngle = ArcTangent(airAcceleration / speed) * (180 / FLOAT_PI);

    return (FloatAbs(currentTurn) > maxTurnAngle);
}

float CalculateMaxTurnRate(int client)
{
	float mx; // Placeholder for mouse X movement, not used in this calculation
	float my; // Placeholder for mouse Y movement, not used in this calculation
	float fCoeff;

	// Player should not be able to turn at all with sensitivity or m_yaw equal to 0
	// so detect them if they are, this is handled elsewhere
	/*
	if((g_mYaw[client] == 0.0 || g_Sensitivity[client] == 0.0) && !(GetClientButtons(client) & (IN_LEFT|IN_RIGHT)))
	{
		g_iIllegalYawCount[client]++;
	}
	*/

	// Calculate mouse sensitivity based on m_customaccel settings
	if(g_mCustomAccel[client] <= 0 || g_mCustomAccel[client] > 3)
	{
		//fCoeff = mx / (g_mYaw[client] * g_Sensitivity[client]);
		fCoeff = g_Sensitivity[client];
	}
	else if(g_mCustomAccel[client] == 1 || g_mCustomAccel[client] == 2)
	{
		float raw_mouse_movement_distance = SquareRoot(mx * mx + my * my); // Placeholder, not used
		float acceleration_scale = g_mCustomAccelScale[client];
		float accelerated_sensitivity_max = g_mCustomAccelMax[client];
		float accelerated_sensitivity_exponent = g_mCustomAccelExponent[client];
		float accelerated_sensitivity = Pow(raw_mouse_movement_distance, accelerated_sensitivity_exponent) * acceleration_scale + g_Sensitivity[client];

		if (accelerated_sensitivity_max > 0.0001 && accelerated_sensitivity > accelerated_sensitivity_max)
		{
			accelerated_sensitivity = accelerated_sensitivity_max;
		}

		fCoeff = accelerated_sensitivity;

		if(g_mCustomAccel[client] == 2)
		{
			fCoeff *= g_mYaw[client];
		}
	}
	else if(g_mCustomAccel[client] == 3)
	{
		//float raw_mouse_movement_distance_squared = (mx * mx) + (my * my);
		//float fExp = MAX(0.0, (g_mCustomAccelExponent[client] - 1.0) / 2.0);
		//float accelerated_sensitivity = Pow(raw_mouse_movement_distance_squared, fExp) * g_Sensitivity[client];

		//PrintToChat(client, "%f %f", raw_mouse_movement_distance_squared, fExp);
		//PrintToChat(client, "%f", accelerated_sensitivity);
		//PrintToChat(client, "%f", mx);

		//fCoeff = accelerated_sensitivity;
		fCoeff = g_Sensitivity[client];

		//return;
	}

	if(g_Engine == Engine_CSS && g_mFilter[client] == true)
	{
		fCoeff /= 4;
	}

	float baseTurnRate = g_mYaw[client] * fCoeff * 1000.0; // Use calculated fCoeff
	return g_mRawInput[client] ? baseTurnRate : baseTurnRate * 1.5;
}

void UpdateTurnHistory(int client, float turn)
{
    g_fTurnHistory[client][g_iTurnHistoryIndex[client]] = turn;
    g_iTurnHistoryIndex[client] = (g_iTurnHistoryIndex[client] + 1) % TURN_HISTORY_SIZE;
}

void UpdateMoveHistory(int client, float sideMove, float forwardMove)
{
    g_fSideMoveHistory[client][g_iMoveHistoryIndex[client]] = sideMove;
    g_fForwardMoveHistory[client][g_iMoveHistoryIndex[client]] = forwardMove;
    g_iMoveHistoryIndex[client] = (g_iMoveHistoryIndex[client] + 1) % MOVE_HISTORY_SIZE;
}

void CheckPreciseTurning(int client, float currentTurn)
{
    if (0.01 < FloatAbs(currentTurn) < 0.1)
    {
        if (++g_iPreciseMovementCount[client] > 20)
        {
            AnticheatLog(client, "Suspiciously precise turning detected");
            g_iPreciseMovementCount[client] = 0;
        }
    }
    else
    {
        g_iPreciseMovementCount[client] = 0;
    }
}

float CalculateTurningSuspicionScore(int client)
{
    float suspicionScore = 0.0;
    int illegalTurns = 0;
    float totalTurnMagnitude = 0.0;
    float maxTurnRate = CalculateMaxTurnRate(client);

    for (int i = 0; i < TURN_HISTORY_SIZE; i++)
    {
        float turn = FloatAbs(g_fTurnHistory[client][i]);
        if (turn > maxTurnRate)
        {
            illegalTurns++;
            totalTurnMagnitude += turn - maxTurnRate;
        }
    }

    float illegalTurnFrequency = float(illegalTurns) / float(TURN_HISTORY_SIZE);
    suspicionScore += illegalTurnFrequency * 0.4;

    float avgIllegalTurnMagnitude = (illegalTurns > 0) ? totalTurnMagnitude / float(illegalTurns) : 0.0;
    suspicionScore += (avgIllegalTurnMagnitude / maxTurnRate) * 0.3;

    suspicionScore += CalculateTurnConsistency(client) * 0.2;

    suspicionScore += (float(g_iIllegalTurnCount[client]) / 1000.0) * 0.1;

    return suspicionScore;
}

float CalculateTurnConsistency(int client)
{
    float sum = 0.0, sumSquared = 0.0;
    int count = 0;

    for (int i = 0; i < TURN_HISTORY_SIZE; i++)
    {
        float turn = FloatAbs(g_fTurnHistory[client][i]);
        if (turn > 0.0)
        {
            sum += turn;
            sumSquared += turn * turn;
            count++;
        }
    }

    if (count < 2) return 0.0;

    float mean = sum / float(count);
    float variance = (sumSquared - (sum * sum / float(count))) / float(count - 1);
    float stdDev = SquareRoot(variance);

    float coefficientOfVariation = stdDev / mean;

    return 1.0 - coefficientOfVariation;
}

float CalculateMoveConsistency(int client)
{
    float sideMoveSum = 0.0, sideMoveSquaredSum = 0.0;
    float forwardMoveSum = 0.0, forwardMoveSquaredSum = 0.0;
    int count = 0;

    for (int i = 0; i < MOVE_HISTORY_SIZE; i++)
    {
        if (g_fSideMoveHistory[client][i] != 0.0 || g_fForwardMoveHistory[client][i] != 0.0)
        {
            sideMoveSum += FloatAbs(g_fSideMoveHistory[client][i]);
            sideMoveSquaredSum += g_fSideMoveHistory[client][i] * g_fSideMoveHistory[client][i];
            
            forwardMoveSum += FloatAbs(g_fForwardMoveHistory[client][i]);
            forwardMoveSquaredSum += g_fForwardMoveHistory[client][i] * g_fForwardMoveHistory[client][i];
            
            count++;
        }
    }

    if (count < 2) return 0.0;

    float sideMoveAvg = sideMoveSum / float(count);
    float forwardMoveAvg = forwardMoveSum / float(count);

    float sideMoveVariance = (sideMoveSquaredSum - (sideMoveSum * sideMoveSum / float(count))) / float(count - 1);
    float forwardMoveVariance = (forwardMoveSquaredSum - (forwardMoveSum * forwardMoveSum / float(count))) / float(count - 1);

    float sideMoveStdDev = SquareRoot(sideMoveVariance);
    float forwardMoveStdDev = SquareRoot(forwardMoveVariance);

    float sideMoveCoefficientOfVariation = (sideMoveAvg != 0.0) ? sideMoveStdDev / sideMoveAvg : 0.0;
    float forwardMoveCoefficientOfVariation = (forwardMoveAvg != 0.0) ? forwardMoveStdDev / forwardMoveAvg : 0.0;

    return 1.0 - ((sideMoveCoefficientOfVariation + forwardMoveCoefficientOfVariation) / 2.0);
}

float CalculateMoveAlternation(int client)
{
    int sideAlternationCount = 0, forwardAlternationCount = 0;
    int totalCount = 0;

    for (int i = 1; i < MOVE_HISTORY_SIZE; i++)
    {
        if ((g_fSideMoveHistory[client][i] != 0.0 || g_fForwardMoveHistory[client][i] != 0.0) &&
            (g_fSideMoveHistory[client][i-1] != 0.0 || g_fForwardMoveHistory[client][i-1] != 0.0))
        {
            sideAlternationCount += (g_fSideMoveHistory[client][i] * g_fSideMoveHistory[client][i-1] < 0.0) ? 1 : 0;
            forwardAlternationCount += (g_fForwardMoveHistory[client][i] * g_fForwardMoveHistory[client][i-1] < 0.0) ? 1 : 0;
            totalCount++;
        }
    }

    return (totalCount > 0) ? float(sideAlternationCount + forwardAlternationCount) / float(totalCount * 2) : 0.0;
}

bool CheckForImpossibleSequences(int client)
{
    float maxAccel = GetConVarFloat(FindConVar("sv_accelerate")) * GetTickInterval() * 2;
    float maxSpeed = GetEntPropFloat(client, Prop_Send, "m_flMaxspeed");

    for (int i = 1; i < MOVE_HISTORY_SIZE; i++)
    {
        float sideDiff = g_fSideMoveHistory[client][i] - g_fSideMoveHistory[client][i-1];
        float forwardDiff = g_fForwardMoveHistory[client][i] - g_fForwardMoveHistory[client][i-1];

        if ((g_fSideMoveHistory[client][i] != 0 && g_fSideMoveHistory[client][i-1] != 0 && FloatAbs(sideDiff) > maxAccel) ||
            (g_fForwardMoveHistory[client][i] != 0 && g_fForwardMoveHistory[client][i-1] != 0 && FloatAbs(forwardDiff) > maxAccel) ||
            (SquareRoot(g_fSideMoveHistory[client][i] * g_fSideMoveHistory[client][i] + 
                        g_fForwardMoveHistory[client][i] * g_fForwardMoveHistory[client][i]) > maxSpeed))
        {
            return true;
        }
    }

    return false;
}

void IncrementIllegalTurnCount(int client)
{
    g_iIllegalTurnCount[client]++;
}

void CheckForWOnlyHack(int client) // not entirely sure what to do with this
{
	if(FloatAbs(g_fAngleDifference[client][1] - g_fLastAngleDifference[client][1]) > 13 && // Player turned more than 13 degrees in 1 tick
	g_fAngleDifference[client][1] != 0.0 &&
	((g_iCmdNum[client] - g_iLastTeleportTick[client]) > 200// &&
	//g_iButtons[client][BT_Move] & (1 << GetOppositeButton(GetDesiredButton(client, g_iLastTurnDir[client])))// &&
	))
	{
		g_iIllegalTurn[client][g_iIllegalTurn_CurrentFrame[client]] = true;
		//PrintToAdmins("%N: %.1f", client, FloatAbs(g_fAngleDifference[client] - g_fLastAngleDifference[client]));
	}
	else
	{
		g_iIllegalTurn[client][g_iIllegalTurn_CurrentFrame[client]] = false;
		//char sTurn[32];
		//GetTurnDirectionName(g_iLastTurnDir[client], sTurn, sizeof(sTurn));
		//PrintToAdmins("No: Diff: %.1f, Btn: %d, Gain: %.1f", FloatAbs(g_fAngleDifference[client] - g_fLastAngleDifference[client]), g_iButtons[client][BT_Move] & (1 << GetOppositeButton(GetDesiredButton(client, g_iLastTurnDir[client]))), GetGainPercent(client));
	}

	g_iIllegalTurn_CurrentFrame[client] = (g_iIllegalTurn_CurrentFrame[client] + 1) % MAX_FRAMES;

	if(g_iIllegalTurn_CurrentFrame[client] == 0)
	{
		int illegalCount, timingCount;
		for(int idx; idx < MAX_FRAMES; idx++)
		{
			if(g_iIllegalTurn[client][idx] == true)
			{
				illegalCount++;
			}

			if(g_iIllegalTurn_IsTiming[client][idx] == true)
			{
				timingCount++;
			}
		}

		float illegalPct, timingPct;
		illegalPct = float(illegalCount) / float(MAX_FRAMES);
		timingPct  = float(timingCount) / float(MAX_FRAMES);
		if(illegalPct > 0.6)
		{
			AnticheatLog(client, "angle snap hack, Pct: %.2f％, Timing: %.1f％", illegalPct * 100.0, timingPct * 100.0);
		}
	}

	return;
}

void CheckForStartKey(int client)
{
	for(int idx; idx < 4; idx++)
	{
		if(!(g_iLastButtons[client][BT_Move] & (1 << idx)) && (g_iButtons[client][BT_Move] & (1 << idx)))
		{
			g_iLastPressTick[client][idx][BT_Move] = g_iCmdNum[client];
		}

		if(!(g_iLastButtons[client][BT_Key] & (1 << idx)) && (g_iButtons[client][BT_Key] & (1 << idx)))
		{
			g_iLastPressTick[client][idx][BT_Key] = g_iCmdNum[client];
		}
	}
}

void ClientPressedKey(int client, int button, int btype)
{
	g_iKeyPressesThisStrafe[client][btype]++;
	// Check if player started a strafe
	if(btype == BT_Move)
	{
		g_iStrafesDone[client]++; // player pressed either w,a,s,d. update strafe count

		int turnDir = GetDesiredTurnDir(client, button, false);

		if(g_iLastTurnDir[client] == turnDir &&
		g_iStartStrafe_LastRecordedTick[client] != g_iCmdNum[client] &&
		g_iLastPressTick[client][button][BT_Move] != g_iLastPressTick_Recorded[client][button][BT_Move] &&
		g_iLastTurnTick[client] != g_iLastTurnTick_Recorded_StartStrafe[client])
		{
			int difference = g_iLastTurnTick[client] - g_iLastPressTick[client][button][BT_Move];

			if(-15 <= difference <= 15)
			{
				RecordStartStrafe(client, button, turnDir, "ClientPressedKey");
			}
		}
	}

	// Check if player finished switching their keys
	int oppositeButton = GetOppositeButton(button);
	int difference = g_iLastPressTick[client][button][btype] - g_iLastReleaseTick[client][oppositeButton][btype];
	if(difference <= 15 && g_iKeySwitch_LastRecordedTick[client][btype] != g_iCmdNum[client] &&
	g_iLastReleaseTick[client][oppositeButton][btype] != g_iLastReleaseTick_Recorded_KS[client][oppositeButton][btype] &&
	g_iLastPressTick[client][button][btype] != g_iLastPressTick_Recorded_KS[client][button][btype])
	{
		RecordKeySwitch(client, button, oppositeButton, btype, "ClientPressedKey");
	}
}

void CheckForTeleport(int client)
{
	float vPos[3];
	GetClientAbsOrigin(client, vPos);

	float distance = SquareRoot(Pow(vPos[0] - g_fLastPosition[client][0], 2.0) +
								Pow(vPos[1] - g_fLastPosition[client][1], 2.0) +
								Pow(vPos[2] - g_fLastPosition[client][2], 2.0));

	if(distance > 35.0)
	{
		g_iLastTeleportTick[client] = g_iCmdNum[client];
	}
}

void CheckForEndKey(int client)
{
	for(int idx; idx < 4; idx++)
	{
		if((g_iLastButtons[client][BT_Move] & (1 << idx)) && !(g_iButtons[client][BT_Move] & (1 << idx)))
		{
			g_iLastReleaseTick[client][idx][BT_Move] = g_iCmdNum[client];
		}

		if((g_iLastButtons[client][BT_Key] & (1 << idx)) && !(g_iButtons[client][BT_Key] & (1 << idx)))
		{
			g_iLastReleaseTick[client][idx][BT_Key] = g_iCmdNum[client];
		}
	}
}

void ClientReleasedKey(int client, int button, int btype)
{
	if(btype == BT_Move)
	{
		// Record end strafe if it is actually an end strafe
		int turnDir = GetDesiredTurnDir(client, button, true);

		if((g_iLastTurnDir[client] == turnDir || g_bIsTurning[client] == false) &&
		g_iEndStrafe_LastRecordedTick[client] != g_iCmdNum[client] &&
		g_iLastReleaseTick_Recorded[client][button][BT_Move] != g_iLastReleaseTick[client][button][BT_Move] &&
		g_iLastTurnTick_Recorded_EndStrafe[client] != g_iLastTurnTick[client])
		{
			int difference = g_iLastTurnTick[client] - g_iLastReleaseTick[client][button][BT_Move];

			if(-15 <= difference <= 15)
			{
				RecordEndStrafe(client, button, turnDir, "ClientReleasedKey");
			}
		}
	}

	// Check if we should record a key switch (BT_Key)
	if(btype == BT_Key)
	{
		int oppositeButton = GetOppositeButton(button);

		if(g_iLastReleaseTick[client][button][BT_Key] - g_iLastPressTick[client][oppositeButton][BT_Key] <= 15 &&
		g_iKeySwitch_LastRecordedTick[client][BT_Key] != g_iCmdNum[client] &&
		g_iLastReleaseTick[client][button][btype] != g_iLastReleaseTick_Recorded_KS[client][button][btype] &&
		g_iLastPressTick[client][oppositeButton][btype] != g_iLastPressTick_Recorded_KS[client][oppositeButton][btype])
		{
			RecordKeySwitch(client, oppositeButton, button, btype, "ClientReleasedKey");
		}
	}
}

void CheckForTurn(int client)
{
	if(g_fAngleDifference[client][1] == 0.0 && g_bIsTurning[client] == true)
	{
		g_iLastStopTurnTick[client] = g_iCmdNum[client];
		g_bIsTurning[client]        = false;
	}
	else if(g_fAngleDifference[client][1] > 0)
	{
		if(g_iLastTurnDir[client] == Turn_Right)
		{
			// Turned left
			g_iLastTurnTick[client] = g_iCmdNum[client];
			g_iLastTurnDir[client]  = Turn_Left;
			g_bIsTurning[client]    = true;
		}
	}
	else if(g_fAngleDifference[client][1] < 0)
	{
		if(g_iLastTurnDir[client] == Turn_Left)
		{
			// Turned right
			g_iLastTurnTick[client] = g_iCmdNum[client];
			g_iLastTurnDir[client]  = Turn_Right;
			g_bIsTurning[client]    = true;
		}
	}
}

void ClientTurned(int client, int turnDir)
{
	// Check if client ended a strafe
	int button         = GetDesiredButton(client, turnDir);

	int oppositeButton = GetOppositeButton(button);
	if(!(g_iButtons[client][BT_Move] & (1 << oppositeButton)) &&
		g_iEndStrafe_LastRecordedTick[client] != g_iCmdNum[client] &&
		g_iReleaseTickAtLastEndStrafe[client][oppositeButton] != g_iLastReleaseTick[client][oppositeButton][BT_Move] &&
		g_iLastTurnTick_Recorded_EndStrafe[client] != g_iLastTurnTick[client])
	{
		int difference = g_iLastTurnTick[client] - g_iLastReleaseTick[client][oppositeButton][BT_Move];

		if(-15 <= difference <= 15)
		{
			RecordEndStrafe(client, oppositeButton, turnDir, "ClientTurned");
		}
	}

	// Check if client just started a strafe
	if(g_iButtons[client][BT_Move] & (1 << button) &&
	g_iStartStrafe_LastRecordedTick[client] != g_iCmdNum[client] &&
	g_iLastPressTick_Recorded[client][button][BT_Move] != g_iLastPressTick[client][button][BT_Move] &&
	g_iLastTurnTick_Recorded_StartStrafe[client] != g_iLastTurnTick[client])
	{
		int difference = g_iLastTurnTick[client] - g_iLastPressTick[client][button][BT_Move];

		if(-15 <= difference <= 15)
		{
			RecordStartStrafe(client, button, turnDir, "ClientTurned");
		}
	}

	// Check if client is cheating on w-only
	CheckForWOnlyHack(client);
}

void ClientStoppedTurning(int client)
{
	int turnDir = g_iLastTurnDir[client];
	int button  = GetDesiredButton(client, turnDir);

	// if client already let go of movement button, and end strafe hasn't been recorded this tick and since they released their key
	if(!(g_iButtons[client][BT_Move] & (1 << button)) &&
		g_iEndStrafe_LastRecordedTick[client] != g_iCmdNum[client] &&
		g_iReleaseTickAtLastEndStrafe[client][button] != g_iLastReleaseTick[client][button][BT_Move] &&
		g_iLastTurnTick_Recorded_EndStrafe[client] != g_iLastStopTurnTick[client])
	{
		int difference = g_iLastStopTurnTick[client] - g_iLastReleaseTick[client][button][BT_Move];

		if(-15 <= difference <= 15)
		{
			RecordEndStrafe(client, button, turnDir, "ClientStoppedTurning");
		}
	}
}

#define MAX_STRAFE_HISTORY 50
#define STRAFE_CONSISTENCY_THRESHOLD 0.95
#define ALTERNATION_CONSISTENCY_THRESHOLD 0.95

enum struct StrafeData
{
    int button;
    int turnDirection;
    int moveDirection;
    int difference;
    int tick;
    bool isTiming;
}

StrafeData g_StartStrafeHistory[MAXPLAYERS + 1][MAX_STRAFE_HISTORY];
StrafeData g_EndStrafeHistory[MAXPLAYERS + 1][MAX_STRAFE_HISTORY];
int g_iStartStrafeHistoryIndex[MAXPLAYERS + 1];
int g_iEndStrafeHistoryIndex[MAXPLAYERS + 1];

stock void RecordStartStrafe(int client, int button, int turnDir, const char[] caller) // i did a lot here and im almost certain it needs pruning
{
    g_iLastPressTick_Recorded[client][button][BT_Move] = g_iLastPressTick[client][button][BT_Move];
    g_iLastTurnTick_Recorded_StartStrafe[client]       = g_iLastTurnTick[client];

    int moveDir   = GetDirection(client);
    int currFrame = g_iStartStrafe_CurrentFrame[client];
    g_iStartStrafe_LastRecordedTick[client] = g_iCmdNum[client];
    g_iStartStrafe_Stats[client][StrafeData_Button][currFrame]        = button;
    g_iStartStrafe_Stats[client][StrafeData_TurnDirection][currFrame] = turnDir;
    g_iStartStrafe_Stats[client][StrafeData_MoveDirection][currFrame] = moveDir;
    g_iStartStrafe_Stats[client][StrafeData_Difference][currFrame]    = g_iLastPressTick[client][button][BT_Move] - g_iLastTurnTick[client];
    g_iStartStrafe_Stats[client][StrafeData_Tick][currFrame]          = g_iCmdNum[client];
    g_bStartStrafe_IsRecorded[client][currFrame] = true;
    g_iStartStrafe_CurrentFrame[client] = (g_iStartStrafe_CurrentFrame[client] + 1) % MAX_FRAMES;

    // record in strafe history
    g_StartStrafeHistory[client][g_iStartStrafeHistoryIndex[client]].button = button;
    g_StartStrafeHistory[client][g_iStartStrafeHistoryIndex[client]].turnDirection = turnDir;
    g_StartStrafeHistory[client][g_iStartStrafeHistoryIndex[client]].moveDirection = moveDir;
    g_StartStrafeHistory[client][g_iStartStrafeHistoryIndex[client]].difference = g_iStartStrafe_Stats[client][StrafeData_Difference][currFrame];
    g_StartStrafeHistory[client][g_iStartStrafeHistoryIndex[client]].tick = g_iCmdNum[client];
    g_iStartStrafeHistoryIndex[client] = (g_iStartStrafeHistoryIndex[client] + 1) % MAX_STRAFE_HISTORY;

    if(g_iStartStrafe_Stats[client][StrafeData_Difference][currFrame] == g_iStartStrafe_LastTickDifference[client] && !IsInLeftRight(client, g_iRealButtons[client]))
    {
        g_iStartStrafe_IdenticalCount[client]++;

        if (g_iStartStrafe_IdenticalCount[client] >= IDENTICAL_STRAFE_MIN)
        {
            AnticheatLog(client, "too many %i strafes in a row (%d)", g_iStartStrafe_LastTickDifference[client], g_iStartStrafe_IdenticalCount[client]);
            AutoBanPlayer(client);
        }
    }
    else
    {
        if (g_iStartStrafe_IdenticalCount[client] >= 15 && g_iStartStrafe_IdenticalCount[client] < IDENTICAL_STRAFE_MIN)
        {
            AnticheatLog(client, "too many %i strafes in a row (%d)", g_iStartStrafe_LastTickDifference[client], g_iStartStrafe_IdenticalCount[client]);
        }

        g_iStartStrafe_LastTickDifference[client] = g_iStartStrafe_Stats[client][StrafeData_Difference][currFrame];
        g_iStartStrafe_IdenticalCount[client] = 0;
    }

    if(g_iStartStrafe_CurrentFrame[client] == 0)
    {
        AnalyzeStartStrafePatterns(client);
    }
}

stock void RecordEndStrafe(int client, int button, int turnDir, const char[] caller) // this one too
{
    g_iReleaseTickAtLastEndStrafe[client][button] = g_iLastReleaseTick[client][button][BT_Move];
    g_iLastReleaseTick_Recorded[client][button][BT_Move] = g_iLastReleaseTick[client][button][BT_Move];
    g_iEndStrafe_LastRecordedTick[client] = g_iCmdNum[client];
    int moveDir = GetDirection(client);
    int currFrame = g_iEndStrafe_CurrentFrame[client];
    g_iEndStrafe_Stats[client][StrafeData_Button][currFrame]        = button;
    g_iEndStrafe_Stats[client][StrafeData_TurnDirection][currFrame] = turnDir;
    g_iEndStrafe_Stats[client][StrafeData_MoveDirection][currFrame] = moveDir;

    int difference = g_iLastReleaseTick[client][button][BT_Move] - g_iLastStopTurnTick[client];
    g_iLastTurnTick_Recorded_EndStrafe[client] = g_iLastStopTurnTick[client];

    if(g_iLastTurnTick[client] > g_iLastStopTurnTick[client])
    {
        difference = g_iLastReleaseTick[client][button][BT_Move] - g_iLastTurnTick[client];
        g_iLastTurnTick_Recorded_EndStrafe[client] = g_iLastTurnTick[client];
    }
    g_iEndStrafe_Stats[client][StrafeData_Difference][currFrame] = difference;
    g_bEndStrafe_IsRecorded[client][currFrame]                   = true;
    g_iEndStrafe_Stats[client][StrafeData_Tick][currFrame]       = g_iCmdNum[client];
    g_iEndStrafe_CurrentFrame[client] = (g_iEndStrafe_CurrentFrame[client] + 1) % MAX_FRAMES;

    // record in strafe history
    g_EndStrafeHistory[client][g_iEndStrafeHistoryIndex[client]].button = button;
    g_EndStrafeHistory[client][g_iEndStrafeHistoryIndex[client]].turnDirection = turnDir;
    g_EndStrafeHistory[client][g_iEndStrafeHistoryIndex[client]].moveDirection = moveDir;
    g_EndStrafeHistory[client][g_iEndStrafeHistoryIndex[client]].difference = difference;
    g_EndStrafeHistory[client][g_iEndStrafeHistoryIndex[client]].tick = g_iCmdNum[client];
    g_iEndStrafeHistoryIndex[client] = (g_iEndStrafeHistoryIndex[client] + 1) % MAX_STRAFE_HISTORY;

    if(g_iEndStrafe_Stats[client][StrafeData_Difference][currFrame] == g_iEndStrafe_LastTickDifference[client] && !IsInLeftRight(client, g_iRealButtons[client]))
    {
        g_iEndStrafe_IdenticalCount[client]++;

        if (g_iEndStrafe_IdenticalCount[client] >= IDENTICAL_STRAFE_MIN)
        {
            AnticheatLog(client, "too many %i strafes in a row (%d)", g_iEndStrafe_LastTickDifference[client], g_iEndStrafe_IdenticalCount[client]);
            AutoBanPlayer(client);
        }
    }
    else
    {
        if (g_iEndStrafe_IdenticalCount[client] >= 15 && g_iEndStrafe_IdenticalCount[client] < IDENTICAL_STRAFE_MIN)
        {
            AnticheatLog(client, "too many %i strafes in a row (%d)", g_iEndStrafe_LastTickDifference[client], g_iEndStrafe_IdenticalCount[client]);
        }

        g_iEndStrafe_LastTickDifference[client] = g_iEndStrafe_Stats[client][StrafeData_Difference][currFrame];
        g_iEndStrafe_IdenticalCount[client] = 0;
    }

    if(g_iEndStrafe_CurrentFrame[client] == 0)
    {
        AnalyzeEndStrafePatterns(client);
    }

    // check key press count
    g_iKeyPressesThisStrafe[client][BT_Move] = 0;
    g_iKeyPressesThisStrafe[client][BT_Key]  = 0;
}

void AnalyzeStartStrafePatterns(int client)
{
    float consistencyScore = CalculateStrafeConsistency(g_StartStrafeHistory[client], MAX_STRAFE_HISTORY);
    float alternationScore = CalculateStrafeAlternation(g_StartStrafeHistory[client], MAX_STRAFE_HISTORY);

    if (consistencyScore > STRAFE_CONSISTENCY_THRESHOLD)
    {
        AnticheatLog(client, "Unusually consistent start strafe timings detected (Score: %.2f)", consistencyScore);
    }

    if (alternationScore > ALTERNATION_CONSISTENCY_THRESHOLD)
    {
        AnticheatLog(client, "Suspiciously perfect alternation in start strafes detected (Score: %.2f)", alternationScore);
    }
}

void AnalyzeEndStrafePatterns(int client)
{
    float consistencyScore = CalculateStrafeConsistency(g_EndStrafeHistory[client], MAX_STRAFE_HISTORY);
    float alternationScore = CalculateStrafeAlternation(g_EndStrafeHistory[client], MAX_STRAFE_HISTORY);

    if (consistencyScore > STRAFE_CONSISTENCY_THRESHOLD)
    {
        AnticheatLog(client, "Unusually consistent end strafe timings detected (Score: %.2f)", consistencyScore);
    }

    if (alternationScore > ALTERNATION_CONSISTENCY_THRESHOLD)
    {
        AnticheatLog(client, "Suspiciously perfect alternation in end strafes detected (Score: %.2f)", alternationScore);
    }
}

float CalculateStrafeConsistency(StrafeData[] strafeHistory, int historySize)
{
    float sum = 0.0, sumSq = 0.0;
    int count = 0;

    for (int i = 0; i < historySize; i++)
    {
        if (strafeHistory[i].tick != 0)
        {
            sum += float(strafeHistory[i].difference);
            sumSq += float(strafeHistory[i].difference * strafeHistory[i].difference);
            count++;
        }
    }

    if (count < 2) return 0.0;

    float mean = sum / float(count);
    float variance = (sumSq - (sum * sum / float(count))) / float(count - 1);
    float stdDev = SquareRoot(variance);

    return 1.0 - (stdDev / mean); // higher score means more consistent
}

float CalculateStrafeAlternation(StrafeData[] strafeHistory, int historySize)
{
    int alternationCount = 0;
    int totalCount = 0;

    for (int i = 1; i < historySize; i++)
    {
        if (strafeHistory[i].tick != 0 && strafeHistory[i-1].tick != 0)
        {
            if (strafeHistory[i].turnDirection != strafeHistory[i-1].turnDirection)
            {
                alternationCount++;
            }
            totalCount++;
        }
    }

    return (totalCount > 0) ? float(alternationCount) / float(totalCount) : 0.0;
}

stock void RecordKeySwitch(int client, int button, int oppositeButton, int btype, const char[] caller) // also needs pruning
{
	// record the data
	int currFrame = g_iKeySwitch_CurrentFrame[client][btype];
	g_iKeySwitch_Stats[client][KeySwitchData_Button][btype][currFrame]      = button;
	g_iKeySwitch_Stats[client][KeySwitchData_Difference][btype][currFrame]  = g_iLastPressTick[client][button][btype] - g_iLastReleaseTick[client][oppositeButton][btype];
	g_bKeySwitch_IsRecorded[client][btype][currFrame]                       = true;
	g_iKeySwitch_LastRecordedTick[client][btype]                            = g_iCmdNum[client];
	g_iKeySwitch_CurrentFrame[client][btype]                                = (g_iKeySwitch_CurrentFrame[client][btype] + 1) % MAX_FRAMES_KEYSWITCH;
	g_iLastPressTick_Recorded_KS[client][button][btype]                     = g_iLastPressTick[client][button][btype];
	g_iLastReleaseTick_Recorded_KS[client][oppositeButton][btype]           = g_iLastReleaseTick[client][oppositeButton][btype];

	// After we have a new set of data, check to see if they are cheating
	if(g_iKeySwitch_CurrentFrame[client][btype] == 0)
	{
		int array[MAX_FRAMES_KEYSWITCH];
		int size, positiveCount, timingCount, nullCount;
		for(int idx; idx < MAX_FRAMES_KEYSWITCH; idx++)
		{
			if(g_bKeySwitch_IsRecorded[client][btype][idx] == true)
			{
				array[idx] = g_iKeySwitch_Stats[client][KeySwitchData_Difference][btype][idx];
				size++;

				if(btype == BT_Key)
				{
					if(g_iKeySwitch_Stats[client][KeySwitchData_Difference][BT_Key][idx] >= 0)
					{
						positiveCount++;
					}
				}

				if(g_iKeySwitch_Stats[client][KeySwitchData_Difference][BT_Key][idx] == 0)
				{
					nullCount++;
				}

				if(g_iKeySwitch_Stats[client][KeySwitchData_IsTiming][btype][idx] == true)
				{
					timingCount++;
				}
			}
		}

		float mean = GetAverage(array, size);
		float sd   = StandardDeviation(array, size, mean);
		float nullPct = float(nullCount) / float(MAX_FRAMES_KEYSWITCH);
		if(sd <= 0.25 || nullPct >= 0.95)
		{
			if(btype == BT_Key)
			{
				if(positiveCount == MAX_FRAMES_KEYSWITCH)
				{
					//PrintToAdmins("%N key switch positive count every frame", client);
				}
			}

			float timingPct, positivePct;
			positivePct = float(positiveCount) / float(MAX_FRAMES_KEYSWITCH);
			timingPct   = float(timingCount) / float(MAX_FRAMES_KEYSWITCH);

			AnticheatLog(client, "key switch %d, avg: %.2f, dev: %.2f, p: %.2f％, nullPct: %.2f, Timing: %.1f", btype, mean, sd, positivePct * 100, nullPct * 100, timingPct * 100);
			if(IsClientInGame(client) && g_hAntiNull.BoolValue)
			{
				// Add a delay to the kick in case they are using an obvious strafehack that would ban them anyway
				CreateTimer(10.0, Timer_NullKick, GetClientUserId(client));
			}
		}
	}
}

public Action Timer_NullKick(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);

	if(client != 1)
	{
		KickClient(client, "Kicked for potentional movement config");
	}
}

// If a player triggers this while they are turning and their turning rate is legal from the CheckForIllegalTurning function, then we can probably autoban
#define INPUT_HISTORY_SIZE 50
#define PERFECT_INPUT_THRESHOLD 0.01
#define RAPID_SWITCH_THRESHOLD 3
#define CONSISTENCY_THRESHOLD 20

float g_fInputHistory[MAXPLAYERS + 1][INPUT_HISTORY_SIZE][2];
int g_iInputHistoryIndex[MAXPLAYERS + 1];

void CheckForIllegalMovement(int client, float vel[3], int buttons)
{
	if (g_bSevereLatgSpike)
    {
        return; // skip this check during severe lag spikes
    }

	// this is for future lag compensation
	float adjustedMoveThreshold = g_cvIllegalMoveThreshold.FloatValue * g_fNormalThresholdMultiplier;

    float currentSideMove = vel[1];
    float currentForwardMove = vel[0];

    UpdateInputHistory(client, currentSideMove, currentForwardMove);

    float suspicionScore = 0.0;

    // check for too consistent input, this isn't fully implemented yet
    if (IsInputTooConsistent(client))
    {
        // suspicionScore += 3.0;
        // AnticheatLog(client, "Too consistent input detected");
    }

    // check for rapid input switching, this isnt fully implemented yet
    if (IsRapidInputSwitch(client))
    {
    	// suspicionScore += 4.0;
        // AnticheatLog(client, "Rapid input switch detected");
    }

    // check for perfect input values, this isnt fully implemented yet
    if (IsPerfectInput(currentSideMove) || IsPerfectInput(currentForwardMove))
    {
        // suspicionScore += 2.0;
        // AnticheatLog(client, "Perfect input value detected");
    }

    // existing checks for invalid button and sidemove combinations
    bool bInvalid = false;
    if ((vel[1] > 0 && (buttons & IN_MOVELEFT)) || 
        (vel[1] > 0 && ((buttons & (IN_MOVELEFT|IN_MOVERIGHT)) == (IN_MOVELEFT|IN_MOVERIGHT))) ||
        (vel[1] < 0 && (buttons & IN_MOVERIGHT)) ||
        (vel[1] < 0 && ((buttons & (IN_MOVELEFT|IN_MOVERIGHT)) == (IN_MOVELEFT|IN_MOVERIGHT))) ||
        (vel[1] == 0.0 && ((buttons & (IN_MOVELEFT|IN_MOVERIGHT)) == IN_MOVELEFT || (buttons & (IN_MOVELEFT|IN_MOVERIGHT)) == IN_MOVERIGHT)) ||
        (vel[1] != 0.0 && !(buttons & (IN_MOVELEFT|IN_MOVERIGHT))))
    {
        bInvalid = true;
        suspicionScore += 5.0;
    }

    if (bInvalid)
    {
        g_InvalidButtonSidemoveCount[client]++;
    }
    else
    {
        g_InvalidButtonSidemoveCount[client] = 0;
    }

	float fMaxMove = (g_Engine == Engine_CSS) ? 400.0 : 450.0;

	if (RoundToFloor(vel[0] * 100.0) % 625 != 0 || RoundToFloor(vel[1] * 100.0) % 625 != 0 ||
		(FloatAbs(vel[0]) != fMaxMove && vel[0] != 0.0) || (FloatAbs(vel[1]) != fMaxMove && vel[1] != 0.0))
	{
		g_iIllegalSidemoveCount[client]++;
		suspicionScore += 3.0;
	}
	else
	{
		g_iIllegalSidemoveCount[client] = 0;
	}

	if ((vel[0] != float(RoundToFloor(vel[0])) || vel[1] != float(RoundToFloor(vel[1]))) || (RoundFloat(vel[0]) % 25 != 0 || RoundFloat(vel[1]) % 25 != 0))
	{
		// extra checks for values that the modulo doesn't pick up
		if (FloatAbs(vel[0]) != 112.500000 && FloatAbs(vel[1]) != 112.500000)
		{
			g_iIllegalSidemoveCount[client]++;
			suspicionScore += 3.0; // change this
		}
	}

    // calculate overall suspicion score
    suspicionScore += CalculateSuspicionScore(client);

    float threshold = GetSuspicionThreshold(client);
    if (suspicionScore > threshold)
    {
        AnticheatLog(client, "Illegal input detected. Suspicion score: %.2f (Threshold: %.2f)", suspicionScore, threshold);
        // consider taking action here, like AutoBanPlayer(client)
    }

    UpdateLastValues(client);
}

void UpdateInputHistory(int client, float sideMove, float forwardMove)
{
    g_fInputHistory[client][g_iInputHistoryIndex[client]][0] = sideMove;
    g_fInputHistory[client][g_iInputHistoryIndex[client]][1] = forwardMove;
    g_iInputHistoryIndex[client] = (g_iInputHistoryIndex[client] + 1) % INPUT_HISTORY_SIZE;
}

float GetSuspicionThreshold(int client)
{
    // base threshold
    float threshold = 10.0;

    // adjust threshold based on player's history
    threshold += g_iIllegalSidemoveCount[client] * 0.5;
    threshold += g_InvalidButtonSidemoveCount[client] * 0.5;

    // cap the threshold
    if (threshold > 20.0){
        threshold = 20.0;
    }
    return threshold;
}

void UpdateLastValues(int client)
{
    g_iLastInvalidButtonCount[client] = g_InvalidButtonSidemoveCount[client];
    g_iLastIllegalSidemoveCount[client] = g_iIllegalSidemoveCount[client];
}

bool IsInputTooConsistent(int client)
{
    int consistentCount = 0;
    float lastSideMove = g_fInputHistory[client][0][0];
    float lastForwardMove = g_fInputHistory[client][0][1];

    for (int i = 1; i < INPUT_HISTORY_SIZE; i++)
    {
        if (g_fInputHistory[client][i][0] == lastSideMove && g_fInputHistory[client][i][1] == lastForwardMove)
        {
            consistentCount++;
        }
        else
        {
            break;
        }
    }

    return (consistentCount >= CONSISTENCY_THRESHOLD);
}

bool IsRapidInputSwitch(int client)
{
    int switchCount = 0;
    float lastSideMove = g_fInputHistory[client][0][0];

    for (int i = 1; i < INPUT_HISTORY_SIZE; i++)
    {
        if (lastSideMove * g_fInputHistory[client][i][0] < 0) // Direction changed
        {
            switchCount++;
            if (switchCount >= RAPID_SWITCH_THRESHOLD)
            {
                return true;
            }
        }
        lastSideMove = g_fInputHistory[client][i][0];
    }

    return false;
}

bool IsPerfectInput(float inputValue)
{
    float perfectValues[] = {-450.0, -400.0, 0.0, 400.0, 450.0};
    for (int i = 0; i < sizeof(perfectValues); i++)
    {
        if (FloatAbs(inputValue - perfectValues[i]) < PERFECT_INPUT_THRESHOLD)
            return true;
    }
    return false;
}

float CalculateSuspicionScore(int client)
{
    float score = 0.0;
    score += g_InvalidButtonSidemoveCount[client] * 0.1;
    score += g_iIllegalSidemoveCount[client] * 0.2;
    // add more factors
    return score;
}

stock void UpdateButtons(int client, float vel[3], int buttons)
{
	g_iLastButtons[client][BT_Move] = g_iButtons[client][BT_Move];
	g_iButtons[client][BT_Move]     = 0;

	if(vel[0] > 0)
	{
		g_iButtons[client][BT_Move] |= (1 << Button_Forward);
	}
	else if(vel[0] < 0)
	{
		g_iButtons[client][BT_Move] |= (1 << Button_Back);
	}

	if(vel[1] > 0)
	{
		g_iButtons[client][BT_Move] |= (1 << Button_Right);
	}
	else if(vel[1] < 0)
	{
		g_iButtons[client][BT_Move] |= (1 << Button_Left);
	}

	g_iLastButtons[client][BT_Key] = g_iButtons[client][BT_Key];
	g_iButtons[client][BT_Key] = 0;

	if(buttons & IN_MOVELEFT)
	{
		g_iButtons[client][BT_Key] |= (1 << Button_Left);
	}
	if(buttons & IN_MOVERIGHT)
	{
		g_iButtons[client][BT_Key] |= (1 << Button_Right);
	}
	if(buttons & IN_FORWARD)
	{
		g_iButtons[client][BT_Key] |= (1 << Button_Forward);
	}
	if(buttons & IN_BACK)
	{
		g_iButtons[client][BT_Key] |= (1 << Button_Back);
	}
}

void UpdateAngles(int client, float angles[3])
{
	for(int i; i < 2; i++)
	{
		g_fAngleDifference[client][i] = angles[i] - g_fLastAngles[client][i];

		if (g_fAngleDifference[client][i] > 180)
			g_fAngleDifference[client][i] -= 360;
		else if(g_fAngleDifference[client][i] < -180)
			g_fAngleDifference[client][i] += 360;
	}
}

stock float FindDegreeAngleFromVectors(float vOldAngle[3], float vNewAngle[3])
{
	float deltaX = vOldAngle[1] - vNewAngle[1];
	float deltaY = vNewAngle[0] - vOldAngle[0];
	float angleInDegrees = ArcTangent2(deltaX, deltaY) * 180 / FLOAT_PI;

	if(angleInDegrees < 0)
	{
		angleInDegrees += 360;
	}

	return angleInDegrees;
}

#define MAX_GAIN_HISTORY 50
#define GAIN_CONSISTENCY_THRESHOLD 0.95
#define GAIN_PATTERN_THRESHOLD 0.98

float g_fGainHistory[MAXPLAYERS + 1][MAX_GAIN_HISTORY];
int g_iGainHistoryIndex[MAXPLAYERS + 1];

void UpdateGains(int client, float vel[3], float angles[3], int buttons)
{
    if (GetEntityFlags(client) & FL_ONGROUND)
    {
        if (g_iTicksOnGround[client] > BHOP_TIME)
        {
            ResetGainStats(client);
        }
        g_iTicksOnGround[client]++;
    }
    else
    {
        if (GetEntityMoveType(client) == MOVETYPE_WALK &&
            GetEntProp(client, Prop_Data, "m_nWaterLevel") < 2 &&
            !(GetEntityFlags(client) & FL_ATCONTROLS))
        {
            bool isYawing = (buttons & IN_LEFT) != (buttons & IN_RIGHT);
            if (!(g_iYawSpeed[client] < 50.0 || !isYawing))
            {
                g_iYawTickCount[client]++;
            }

            float gaincoeff;
            g_strafeTick[client]++;
            if (g_strafeTick[client] == 1000)
            {
                g_flRawGain[client] *= 998.0/999.0;
                g_strafeTick[client]--;
            }

            float velocity[3];
            GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", velocity);

            float speed = GetVectorLength(velocity);
            float fore[3], side[3], wishvel[3], wishdir[3];
            float wishspeed, wishspd, currentgain;

            GetAngleVectors(angles, fore, side, NULL_VECTOR);

            fore[2] = 0.0;
            side[2] = 0.0;
            NormalizeVector(fore, fore);
            NormalizeVector(side, side);

            for (int i = 0; i < 2; i++)
                wishvel[i] = fore[i] * vel[0] + side[i] * vel[1];

            wishspeed = NormalizeVector(wishvel, wishdir);
            if (wishspeed > GetEntPropFloat(client, Prop_Send, "m_flMaxspeed")) wishspeed = GetEntPropFloat(client, Prop_Send, "m_flMaxspeed");

            if (wishspeed)
            {
                wishspd = (wishspeed > 30.0) ? 30.0 : wishspeed;

                currentgain = GetVectorDotProduct(velocity, wishdir);
                if (currentgain < 30.0)
                    gaincoeff = (wishspd - FloatAbs(currentgain)) / wishspd;
                
                // adjust gain coefficient based on speed
                gaincoeff *= (1.0 + (speed / 1000.0));  // increase sensitivity at higher speeds

                if (g_bTouchesWall[client] && gaincoeff > 0.5)
                {
                    gaincoeff -= 1;
                    gaincoeff = FloatAbs(gaincoeff);
                }

                if (!g_bTouchesFuncRotating[client])
                {
                    g_flRawGain[client] += gaincoeff;
                    UpdateGainHistory(client, gaincoeff);
                }

                // check for consistent gains
                if (g_strafeTick[client] % 50 == 0)
                {
                    CheckGainConsistency(client);
                    CheckGainPatterns(client);
                }
            }
        }
        g_iTicksOnGround[client] = 0;
    }
}

void ResetGainStats(int client)
{
    g_iJump[client] = 0;
    g_strafeTick[client] = 0;
    g_flRawGain[client] = 0.0;
    g_iYawTickCount[client] = 0;
    g_iTimingTickCount[client] = 0;
    g_iStrafesDone[client] = 0;
    g_bFirstSixJumps[client] = true;
    
    // reset gain history
    for (int i = 0; i < MAX_GAIN_HISTORY; i++)
    {
        g_fGainHistory[client][i] = 0.0;
    }
    g_iGainHistoryIndex[client] = 0;
}

void UpdateGainHistory(int client, float gain)
{
    g_fGainHistory[client][g_iGainHistoryIndex[client]] = gain;
    g_iGainHistoryIndex[client] = (g_iGainHistoryIndex[client] + 1) % MAX_GAIN_HISTORY;
}

void CheckGainConsistency(int client)
{
    float sum = 0.0;
    float sumSquared = 0.0;
    int count = 0;

    for (int i = 0; i < MAX_GAIN_HISTORY; i++)
    {
        if (g_fGainHistory[client][i] != 0.0)
        {
            sum += g_fGainHistory[client][i];
            sumSquared += g_fGainHistory[client][i] * g_fGainHistory[client][i];
            count++;
        }
    }

    if (count > 1)
    {
        float mean = sum / float(count);
        float variance = (sumSquared - (sum * sum / float(count))) / float(count - 1);
        float stdDev = SquareRoot(variance);
        float consistencyScore = 1.0 - (stdDev / mean);

        if (consistencyScore > GAIN_CONSISTENCY_THRESHOLD)
        {
            AnticheatLog(client, "Suspiciously consistent gain values detected (Score: %.2f)", consistencyScore);
        }
    }
}

void CheckGainPatterns(int client)
{
    int patternLength = 5;
    int matchCount = 0;
    int totalPatterns = 0;

    for (int i = 0; i < MAX_GAIN_HISTORY - patternLength; i++)
    {
        bool isMatch = true;
        for (int j = 0; j < patternLength; j++)
        {
            if (FloatAbs(g_fGainHistory[client][i+j] - g_fGainHistory[client][(i+j+patternLength) % MAX_GAIN_HISTORY]) > 0.001)
            {
                isMatch = false;
                break;
            }
        }
        if (isMatch)
        {
            matchCount++;
        }
        totalPatterns++;
    }

    if (totalPatterns > 0)
    {
        float patternScore = float(matchCount) / float(totalPatterns);
        if (patternScore > GAIN_PATTERN_THRESHOLD)
        {
            AnticheatLog(client, "Suspicious gain value patterns detected (Score: %.2f)", patternScore);
        }
    }
}

bool IsInLeftRight(int client, int buttons)
{
	bool isYawing = false;
	if(buttons & IN_LEFT) isYawing = !isYawing;
	if(buttons & IN_RIGHT) isYawing = !isYawing;
	if(!(g_iYawSpeed[client] < 50.0 || isYawing == false))
	{
		return true;
	}

	return false;
}

float GetGainPercent(int client)
{
	if(g_strafeTick[client] == 0)
	{
		return 0.0;
	}

	float coeffsum = g_flRawGain[client];
	coeffsum /= g_strafeTick[client];
	coeffsum *= 100.0; // nothing to see here
	coeffsum = RoundToFloor(coeffsum * 100.0 + 0.5) / 100.0;

	return coeffsum;
}

int GetDesiredTurnDir(int client, int button, bool opposite)
{
	int direction = GetDirection(client);
	int desiredTurnDir = -1;

	// if holding a and going forward then look for left turn
	if(button == Button_Left && direction == Moving_Forward)
	{
		desiredTurnDir = Turn_Left;
	}

	// if holding d and going forward then look for right turn
	else if(button == Button_Right && direction == Moving_Forward)
	{
		desiredTurnDir = Turn_Right;
	}

	// if holding a and going backward then look for right turn
	else if(button == Button_Left && direction == Moving_Back)
	{
		desiredTurnDir = Turn_Right;
	}

	// if holding d and going backward then look for left turn
	else if(button == Button_Right && direction == Moving_Back)
	{
		desiredTurnDir = Turn_Left;
	}

	// if holding w and going left then look for right turn
	else if(button == Button_Forward && direction == Moving_Left)
	{
		desiredTurnDir = Turn_Right;
	}

	// if holding s and going left then look for left turn
	else if(button == Button_Back && direction == Moving_Left)
	{
		desiredTurnDir = Turn_Left;
	}

	// if holding w and going right then look for left turn
	else if(button == Button_Forward && direction == Moving_Right)
	{
		desiredTurnDir = Turn_Left;
	}

	// if holding s and going right then look for right turn
	else if(button == Button_Back && direction == Moving_Right)
	{
		desiredTurnDir = Turn_Right;
	}

	if(opposite == true)
	{
		if(desiredTurnDir == Turn_Right)
		{
			return Turn_Left;
		}
		else
		{
			return Turn_Right;
		}
	}

	return desiredTurnDir;
}

int GetDesiredButton(int client, int dir)
{
	int moveDir = GetDirection(client);
	if(dir == Turn_Left)
	{
		if(moveDir == Moving_Forward)
		{
			return Button_Left;
		}
		else if(moveDir == Moving_Back)
		{
			return Button_Right;
		}
		else if(moveDir == Moving_Left)
		{
			return Button_Back;
		}
		else if(moveDir == Moving_Right)
		{
			return Button_Forward;
		}
	}
	else if(dir == Turn_Right)
	{
		if(moveDir == Moving_Forward)
		{
			return Button_Right;
		}
		else if(moveDir == Moving_Back)
		{
			return Button_Left;
		}
		else if(moveDir == Moving_Left)
		{
			return Button_Forward;
		}
		else if(moveDir == Moving_Right)
		{
			return Button_Back;
		}
	}

	return 0;
}

int GetOppositeButton(int button)
{
	if(button == Button_Forward)
	{
		return Button_Back;
	}
	else if(button == Button_Back)
	{
		return Button_Forward;
	}
	else if(button == Button_Right)
	{
		return Button_Left;
	}
	else if(button == Button_Left)
	{
		return Button_Right;
	}

	return -1;
}

int GetDirection(int client)
{
	float vVel[3];
	GetEntPropVector(client, Prop_Data, "m_vecVelocity", vVel);

	float vAng[3];
	GetClientEyeAngles(client, vAng);

	float movementDiff = ArcTangent(vVel[1] / vVel[0]) * 180.0 / FLOAT_PI;

	if (vVel[0] < 0.0)
	{
		if (vVel[1] > 0.0)
			movementDiff += 180.0;
		else
			movementDiff -= 180.0;
	}

	if(movementDiff < 0.0)
		movementDiff += 360.0;

	if(vAng[1] < 0.0)
		vAng[1] += 360.0;

	movementDiff = movementDiff - vAng[1];

	bool flipped = false;

	if(movementDiff < 0.0)
	{
		flipped = true;
		movementDiff = -movementDiff;
	}

	if(movementDiff > 180.0)
	{
		if(flipped)
			flipped = false;
		else
			flipped = true;

		movementDiff = FloatAbs(movementDiff - 360.0);
	}

	if(-0.1 < movementDiff < 67.5)
	{
		return Moving_Forward; // Forwards
	}
	if(67.5 < movementDiff < 112.5)
	{
		if(flipped)
		{
			return Moving_Right; // Sideways
		}
		else
		{
			return Moving_Left; // Sideways other way
		}
	}
	if(112.5 < movementDiff <= 180.0)
	{
		return Moving_Back; // Backwards
	}
	return 0; // Unknown should never happend
}

stock void GetTurnDirectionName(int direction, char[] buffer, int maxlength)
{
	if(direction == Turn_Left)
	{
		FormatEx(buffer, maxlength, "Left");
	}
	else if(direction == Turn_Right)
	{
		FormatEx(buffer, maxlength, "Right");
	}
	else
	{
		FormatEx(buffer, maxlength, "Unknown");
	}
}

stock void GetMoveDirectionName(int direction, char[] buffer, int maxlength)
{
	if(direction == Moving_Forward)
	{
		FormatEx(buffer, maxlength, "Forward");
	}
	else if(direction == Moving_Back)
	{
		FormatEx(buffer, maxlength, "Backward");
	}
	else if(direction == Moving_Left)
	{
		FormatEx(buffer, maxlength, "Left");
	}
	else if(direction == Moving_Right)
	{
		FormatEx(buffer, maxlength, "Right");
	}
	else
	{
		FormatEx(buffer, maxlength, "Unknown");
	}
}

/**
* Gets a client's velocity with extra settings to disallow velocity on certain axes
*/
stock float GetClientVelocity(int client, bool UseX, bool UseY, bool UseZ)
{
	float vVel[3];

	if(UseX)
	{
		vVel[0] = GetEntPropFloat(client, Prop_Send, "m_vecVelocity[0]");
	}

	if(UseY)
	{
		vVel[1] = GetEntPropFloat(client, Prop_Send, "m_vecVelocity[1]");
	}

	if(UseZ)
	{
		vVel[2] = GetEntPropFloat(client, Prop_Send, "m_vecVelocity[2]");
	}

	return GetVectorLength(vVel);
} 
