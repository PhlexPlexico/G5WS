/**
 * =============================================================================
 * Get5 Web Stats (G5WS)
 * Copyright (C) 2021. Sean Lewis/Phlex Plexico.  All rights reserved.
 * =============================================================================
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#include "include/get5.inc"
#include "include/logdebug.inc"
#include <cstrike>
#include <sourcemod>

#include "get5/util.sp"

#include <SteamWorks>
#include <json>  // github.com/clugg/sm-json

#define PLUGIN_VERSION "4.0.0"

#include "get5/jsonhelpers.sp"

#pragma semicolon 1
#pragma newdecls required

ConVar g_UseSVGCvar;
char g_LogoBasePath[128];
ConVar g_APIKeyCvar;
char g_APIKey[128];

ConVar g_APIURLCvar;
char g_APIURL[128];

char g_storedAPIURL[128];
char g_storedAPIKey[128];

ConVar g_EnableDemoUpload;
ConVar g_EnableSupportMessage;

#define LOGO_DIR "materials/panorama/images/tournaments/teams"
#define LEGACY_LOGO_DIR "resource/flash/econ/tournaments/teams"

// clang-format off
public Plugin myinfo = {
  name = "G5WS - Get5 Web Stats",
  author = "phlexplexico",
  description = "Sends and receives match information to/from G5API.",
  version = PLUGIN_VERSION,
  url = "https://github.com/phlexplexico/G5WS"
};
// clang-format on

public void OnPluginStart() {
  InitDebugLog("get5_debug", "G5WS");
  LogDebug("OnPluginStart version=%s", PLUGIN_VERSION);
  g_UseSVGCvar = CreateConVar("get5_use_svg", "1", "support svg team logos");
  HookConVarChange(g_UseSVGCvar, LogoBasePathChanged);
  g_LogoBasePath = g_UseSVGCvar.BoolValue ? LOGO_DIR : LEGACY_LOGO_DIR;
  g_APIKeyCvar =
      CreateConVar("get5_web_api_key", "", "Match API key, this is automatically set through rcon");
  HookConVarChange(g_APIKeyCvar, ApiInfoChanged);

  g_APIURLCvar = CreateConVar("get5_web_api_url", "", "URL the get5 api is hosted at");

  HookConVarChange(g_APIURLCvar, ApiInfoChanged);

  g_EnableDemoUpload = CreateConVar("get5_upload_demos", "1", "Upload demo on post match.");

  g_EnableSupportMessage = CreateConVar("get5_api_support_message", "1", "Enable a dono message every half time.");


  RegConsoleCmd("get5_web_available", Command_Available);
}

public Action Command_Available(int client, int args) {
  char versionString[64] = "unknown";
  ConVar versionCvar = FindConVar("get5_version");
  if (versionCvar != null) {
    versionCvar.GetString(versionString, sizeof(versionString));
  }

  JSON_Object json = new JSON_Object();

  json.SetInt("gamestate", view_as<int>(Get5_GetGameState()));
  json.SetInt("available", 1);
  json.SetString("plugin_version", versionString);

  char buffer[256];
  json.Encode(buffer, sizeof(buffer), true);
  ReplyToCommand(client, buffer);

  json_cleanup_and_delete(json);

  return Plugin_Handled;
}

public void LogoBasePathChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
  g_LogoBasePath = g_UseSVGCvar.BoolValue ? LOGO_DIR : LEGACY_LOGO_DIR;
}

public void ApiInfoChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
  g_APIKeyCvar.GetString(g_APIKey, sizeof(g_APIKey));
  g_APIURLCvar.GetString(g_APIURL, sizeof(g_APIURL));

  // Add a trailing backslash to the api url if one is missing.
  int len = strlen(g_APIURL);
  if (len > 0 && g_APIURL[len - 1] != '/') {
    StrCat(g_APIURL, sizeof(g_APIURL), "/");
  }

  LogDebug("get5_web_api_url now set to %s", g_APIURL);
}

static Handle CreateRequest(EHTTPMethod httpMethod, const char[] apiMethod, any:...) {
  char url[1024];
  Format(url, sizeof(url), "%s%s", g_APIURL, apiMethod);

  char formattedUrl[1024];
  VFormat(formattedUrl, sizeof(formattedUrl), url, 3);

  LogDebug("Trying to create request to url %s", formattedUrl);

  Handle req = SteamWorks_CreateHTTPRequest(httpMethod, formattedUrl);
  if (StrEqual(g_APIKey, "") && StrEqual(g_storedAPIKey, "")) {
    // Not using a web interface.
    return INVALID_HANDLE;
  } else if (req == INVALID_HANDLE) {
    LogError("Failed to create request to %s", formattedUrl);
    return INVALID_HANDLE;

  } else {
    SteamWorks_SetHTTPCallbacks(req, RequestCallback);
    if (StrEqual(g_APIKey, "")) {
      AddStringParam(req, "key", g_storedAPIKey);
    } else {
      AddStringParam(req, "key", g_APIKey);
    }
    
    return req;
  }
}

static Handle CreateRequestNoKey(EHTTPMethod httpMethod, const char[] apiMethod, any:...) {
  char url[1024];
  Format(url, sizeof(url), "%s%s", g_APIURL, apiMethod);

  char formattedUrl[1024];
  VFormat(formattedUrl, sizeof(formattedUrl), url, 3);

  LogDebug("Trying to create request to url %s", formattedUrl);

  Handle req = SteamWorks_CreateHTTPRequest(httpMethod, formattedUrl);
  if (req == INVALID_HANDLE) {
    // Failed to init.
    LogError("Failed to create request to %s", formattedUrl);
    return INVALID_HANDLE;
  } else {
    SteamWorks_SetHTTPCallbacks(req, RequestCallback);  
    return req;
  }
}

public int RequestCallback(Handle request, bool failure, bool requestSuccessful,
                    EHTTPStatusCode statusCode) {
  if (failure || !requestSuccessful) {
    LogError("API request failed, HTTP status code = %d", statusCode);
    char response[1024];
    SteamWorks_GetHTTPResponseBodyData(request, response, sizeof(response));
    LogError(response);
  }
  delete request;
  return;
}

public void Get5_OnSeriesInit(const Get5SeriesStartedEvent event) {
  // Handle new logos.
  if (!DirExists(g_LogoBasePath)) {
    if (!CreateDirectory(g_LogoBasePath, 755)) {
      LogError("Failed to create logo directory: %s", g_LogoBasePath);
    }
  }

  char logo1[32];
  char logo2[32];
  GetConVarStringSafe("mp_teamlogo_1", logo1, sizeof(logo1));
  GetConVarStringSafe("mp_teamlogo_2", logo2, sizeof(logo2));
  CheckForLogo(logo1);
  CheckForLogo(logo2);
}

public void CheckForLogo(const char[] logo) {
  if (StrEqual(logo, "")) {
    return;
  }

  char logoPath[PLATFORM_MAX_PATH + 1];
  char endPoint[32];
  // change png to svg because it's better supported
  if (g_UseSVGCvar.BoolValue) {
    Format(logoPath, sizeof(logoPath), "%s/%s.svg", g_LogoBasePath, logo);
    Format(endPoint, sizeof(endPoint), "static/img/logos/%s.svg", logo);
  } else {
    Format(logoPath, sizeof(logoPath), "%s/%s.png", g_LogoBasePath, logo);
    Format(endPoint, sizeof(endPoint), "static/img/logos/%s.png", logo);
  }

  // Try to fetch the file if we don't have it.
  if (!FileExists(logoPath)) {
    LogDebug("Fetching logo for %s", logo);
    Handle req = CreateRequest(k_EHTTPMethodGET, endPoint, logo);

    if (req == INVALID_HANDLE) {
      return;
    }

    Handle pack = CreateDataPack();
    WritePackString(pack, logo);

    SteamWorks_SetHTTPRequestContextValue(req, view_as<int>(pack));
    SteamWorks_SetHTTPCallbacks(req, LogoCallback);
    SteamWorks_SendHTTPRequest(req);
  }
}

public int DemoCallback(Handle request, bool failure, bool successful, EHTTPStatusCode status, int data) {
  if (failure || !successful) {
    LogError("Demo request failed, status code = %d", status);
  }
  delete request;
  return;
}

public int LogoCallback(Handle request, bool failure, bool successful, EHTTPStatusCode status, int data) {
  if (failure || !successful) {
    LogError("Logo request failed, status code = %d", status);
    delete request;
    return;
  }

  DataPack pack = view_as<DataPack>(data);
  pack.Reset();
  char logo[32];
  pack.ReadString(logo, sizeof(logo));

  char logoPath[PLATFORM_MAX_PATH + 1];
  if (g_UseSVGCvar.BoolValue) {
    Format(logoPath, sizeof(logoPath), "%s/%s.svg", g_LogoBasePath, logo);
  } else {
    Format(logoPath, sizeof(logoPath), "%s/%s.png", g_LogoBasePath, logo);
  }

  LogMessage("Saved logo for %s to %s, adding to download table.", logo, logoPath);
  SteamWorks_WriteHTTPResponseBodyToFile(request, logoPath);

  AddFileToDownloadsTable(logoPath);
  delete request;
}

public void Get5_OnGoingLive(const Get5GoingLiveEvent event) {
  char mapName[64];
  GetCurrentMap(mapName, sizeof(mapName));

  char matchId[64];
  event.GetMatchId(matchId, sizeof(matchId));

  Handle req = CreateRequest(k_EHTTPMethodPOST, "match/%s/map/%d/start", matchId, event.MapNumber);
  if (req != INVALID_HANDLE) {
    AddStringParam(req, "mapname", mapName);
    SteamWorks_SendHTTPRequest(req);
  }

  // Store Cvar since it gets reset after match finishes?
  if (g_EnableDemoUpload.BoolValue) {
    Format(g_storedAPIKey, sizeof(g_storedAPIKey), g_APIKey);
    Format(g_storedAPIURL, sizeof(g_storedAPIURL), g_APIURL);
  }

  Get5_AddLiveCvar("get5_web_api_key", g_APIKey);
  Get5_AddLiveCvar("get5_web_api_url", g_APIURL);
}

public void UpdateRoundStats(const char[] matchId, int mapNumber) {
  int t1score = CS_GetTeamScore(Get5_Get5TeamToCSTeam(Get5Team_1));
  int t2score = CS_GetTeamScore(Get5_Get5TeamToCSTeam(Get5Team_2));
  LogDebug("Updating round stats...");
  Handle req = CreateRequest(k_EHTTPMethodPOST, "match/%s/map/%d/update", matchId, mapNumber);
  if (req != INVALID_HANDLE) {
    AddIntParam(req, "team1score", t1score);
    AddIntParam(req, "team2score", t2score);
    SteamWorks_SendHTTPRequest(req);
  }

  KeyValues kv = new KeyValues("Stats");
  Get5_GetMatchStats(kv);
  char mapKey[32];
  Format(mapKey, sizeof(mapKey), "map%d", mapNumber);
  if (kv.JumpToKey(mapKey)) {
    if (kv.JumpToKey("team1")) {
      UpdatePlayerStats(matchId, kv, Get5Team_1);
      kv.GoBack();
    }
    if (kv.JumpToKey("team2")) {
      UpdatePlayerStats(matchId, kv, Get5Team_2);
      kv.GoBack();
    }
    kv.GoBack();
  }
  delete kv;
}

public void Get5_OnMapResult(const Get5MapResultEvent event) {
  char matchId[64];
  event.GetMatchId(matchId, sizeof(matchId));

  char winnerString[64];
  GetTeamString(event.Winner.Team, winnerString, sizeof(winnerString));

  Handle req = CreateRequest(k_EHTTPMethodPOST, "match/%s/map/%d/finish", matchId, event.MapNumber);
  if (req != INVALID_HANDLE) {
    AddIntParam(req, "team1score", event.Team1Score);
    AddIntParam(req, "team2score", event.Team2Score);
    AddStringParam(req, "winner", winnerString);
    SteamWorks_SendHTTPRequest(req);
  }
}

static void AddIntStat(Handle req, KeyValues kv, const char[] field) {
  AddIntParam(req, field, kv.GetNum(field));
}

public void UpdatePlayerStats(const char[] matchId, KeyValues kv, Get5Team team) {
  char name[MAX_NAME_LENGTH];
  char auth[AUTH_LENGTH];
  int mapNumber = Get5_GetMapNumber();

  if (kv.GotoFirstSubKey()) {
    do {
      kv.GetSectionName(auth, sizeof(auth));
      kv.GetString("name", name, sizeof(name));
      char teamString[16];
      GetTeamString(team, teamString, sizeof(teamString));

      Handle req = CreateRequest(k_EHTTPMethodPOST, "match/%s/map/%d/player/%s/update", matchId,
                                 mapNumber, auth);
      if (req != INVALID_HANDLE) {
        AddStringParam(req, "team", teamString);
        AddStringParam(req, STAT_NAME, name);
        AddIntStat(req, kv, STAT_KILLS);
        AddIntStat(req, kv, STAT_DEATHS);
        AddIntStat(req, kv, STAT_ASSISTS);
        AddIntStat(req, kv, STAT_FLASHBANG_ASSISTS);
        AddIntStat(req, kv, STAT_TEAMKILLS);
        AddIntStat(req, kv, STAT_SUICIDES);
        AddIntStat(req, kv, STAT_DAMAGE);
        AddIntStat(req, kv, STAT_UTILITY_DAMAGE);
        AddIntStat(req, kv, STAT_ENEMIES_FLASHED);
        AddIntStat(req, kv, STAT_FRIENDLIES_FLASHED);
        AddIntStat(req, kv, STAT_KNIFE_KILLS);
        AddIntStat(req, kv, STAT_HEADSHOT_KILLS);
        AddIntStat(req, kv, STAT_ROUNDSPLAYED);
        AddIntStat(req, kv, STAT_BOMBPLANTS);
        AddIntStat(req, kv, STAT_BOMBDEFUSES);
        AddIntStat(req, kv, STAT_1K);
        AddIntStat(req, kv, STAT_2K);
        AddIntStat(req, kv, STAT_3K);
        AddIntStat(req, kv, STAT_4K);
        AddIntStat(req, kv, STAT_5K);
        AddIntStat(req, kv, STAT_V1);
        AddIntStat(req, kv, STAT_V2);
        AddIntStat(req, kv, STAT_V3);
        AddIntStat(req, kv, STAT_V4);
        AddIntStat(req, kv, STAT_V5);
        AddIntStat(req, kv, STAT_FIRSTKILL_T);
        AddIntStat(req, kv, STAT_FIRSTKILL_CT);
        AddIntStat(req, kv, STAT_FIRSTDEATH_T);
        AddIntStat(req, kv, STAT_FIRSTDEATH_CT);
        AddIntStat(req, kv, STAT_TRADEKILL);
        AddIntStat(req, kv, STAT_KAST);
        AddIntStat(req, kv, STAT_CONTRIBUTION_SCORE);
        AddIntStat(req, kv, STAT_MVP);
        AddIntStat(req, kv, STAT_UTILITY_DAMAGE);
        AddIntStat(req, kv, STAT_KNIFE_KILLS);
        AddIntStat(req, kv, STAT_ENEMIES_FLASHED);
        AddIntStat(req, kv, STAT_FRIENDLIES_FLASHED);
        SteamWorks_SendHTTPRequest(req);
      }

    } while (kv.GotoNextKey());
    kv.GoBack();
  }
}

static void AddStringParam(Handle request, const char[] key, const char[] value) {
  if (!SteamWorks_SetHTTPRequestGetOrPostParameter(request, key, value)) {
    LogError("Failed to add http param %s=%s", key, value);
  } else {
    LogDebug("Added param %s=%s to request", key, value);
  }
}

static void AddIntParam(Handle request, const char[] key, int value) {
  char buffer[32];
  IntToString(value, buffer, sizeof(buffer));
  AddStringParam(request, key, buffer);
}

public void Get5_OnSidePicked(const Get5SidePickedEvent event) {
  // Note: CS_TEAM_CT = 3, CS_TEAM_T = 2
  char matchId[64];
  char teamString[64];
  char mapName[64];
  char charSide[3];
  event.GetMatchId(matchId, sizeof(matchId));
  event.GetMapName(mapName, sizeof(mapName));
  GetTeamString(event.Team, teamString, sizeof(teamString));
  LogDebug("Side Choice for Map veto: Side picked %d on map %s for team %s", event.Side, mapName, event.Team);
  Handle req = CreateRequest(k_EHTTPMethodPOST, "match/%s/vetoSideUpdate", matchId);
  if (event.Side == Get5Side_CT) {
    Format(charSide, sizeof(charSide), "CT");
  } else if (event.Side == Get5Side_T) {
    Format(charSide, sizeof(charSide), "T");
  } else {
    Format(charSide, sizeof(charSide), "UNK");
  }
  if (req != INVALID_HANDLE) {
    AddStringParam(req, "map", mapName);
    AddStringParam(req, "teamString", teamString);
    AddStringParam(req, "side", charSide);
    SteamWorks_SendHTTPRequest(req);
  }
}

public void Get5_OnMapVetoed(const Get5MapVetoedEvent event){
  char matchId[64];
  char teamString[64];
  char mapName[64];
  event.GetMatchId(matchId, sizeof(matchId));
  event.GetMapName(mapName, sizeof(mapName));
  GetTeamString(event.Team, teamString, sizeof(teamString));
  
  Handle req = CreateRequest(k_EHTTPMethodPOST, "match/%s/vetoUpdate", matchId);
  if (req != INVALID_HANDLE) {
    AddStringParam(req, "map", mapName);
    AddStringParam(req, "teamString", teamString);
    AddStringParam(req, "pick_or_veto", "ban");  
    SteamWorks_SendHTTPRequest(req);
  }
}

public void Get5_OnMapPicked(const Get5MapPickedEvent event){
  LogDebug("Accepted Map Pick.");
  char teamString[64];
  char matchId[64];
  char mapName[64];

  event.GetMatchId(matchId, sizeof(matchId));
  event.GetMapName(mapName, sizeof(mapName));
  GetTeamString(event.Team, teamString, sizeof(teamString));
  Handle req = CreateRequest(k_EHTTPMethodPOST, "match/%s/vetoUpdate", matchId);
  if (req != INVALID_HANDLE) {
    AddStringParam(req, "map", mapName);
    AddStringParam(req, "teamString", teamString);
    AddStringParam(req, "pick_or_veto", "pick");
    SteamWorks_SendHTTPRequest(req);
  }
}

public void Get5_OnSeriesResult(const Get5SeriesResultEvent event) {
  char winnerString[64];
  char matchId[64];

  event.GetMatchId(matchId, sizeof(matchId));
  GetTeamString(event.Winner.Team, winnerString, sizeof(winnerString));
  
  bool isCancelled = StrEqual(winnerString, "none", false);
  ConVar timeToStartCvar = FindConVar("get5_time_to_start");
  KeyValues kv = new KeyValues("Stats");
  Get5_GetMatchStats(kv);
  bool forfeit = kv.GetNum(STAT_SERIES_FORFEIT, 0) != 0;
  delete kv;

  Handle req = CreateRequest(k_EHTTPMethodPOST, "match/%s/finish", matchId);
  // Need to check that we are indeed a best of two match as well.
  // This has been a source of double sending match results and producing errors.
  // So we really need to check if we are in an edge case BO2 where a score is 1-1.
  if (req != INVALID_HANDLE && (event.Team1SeriesScore == event.Team2SeriesScore || !isCancelled)) {
    AddStringParam(req, "winner", winnerString);
    AddIntParam(req, "team1score", event.Team1SeriesScore);
    AddIntParam(req, "team2score", event.Team2SeriesScore);
    AddIntParam(req, "forfeit", forfeit);
    SteamWorks_SendHTTPRequest(req);
  } else if (req != INVALID_HANDLE && (forfeit && isCancelled && timeToStartCvar.IntValue > 0)) {
    AddStringParam(req, "winner", winnerString);
    AddIntParam(req, "team1score", event.Team1SeriesScore);
    AddIntParam(req, "team2score", event.Team2SeriesScore);
    AddIntParam(req, "forfeit", forfeit);
    SteamWorks_SendHTTPRequest(req);
  }
  g_APIKeyCvar.SetString("");
}

public void Get5_OnDemoFinished(const Get5DemoFinishedEvent event){
  char filename[128];
  char matchId[64];
  event.GetMatchId(matchId, sizeof(matchId));
  event.GetFileName(filename, sizeof(filename));
  // Check if demos upload enabled, and filename is not empty.
  if (g_EnableDemoUpload.BoolValue && filename[0]) {
    LogDebug("About to enter UploadDemo. SO YES WE ARE. Our match ID is %s", matchId);
    int mapNumber = event.MapNumber;
    Handle req = CreateRequest(k_EHTTPMethodPOST, "match/%s/map/%d/demo", matchId, mapNumber);
    LogDebug("Our api url: %s", g_storedAPIURL);
    // Send demo file name to store in database to show users at end of match.
    if (req != INVALID_HANDLE) {
      LogDebug("Our demo string: %s", filename);
      AddStringParam(req, "demoFile", filename);
      SteamWorks_SendHTTPRequest(req);
      Handle fileReq = CreateRequestNoKey(
        k_EHTTPMethodPUT, "match/%s/map/%d/demo/upload/%s", matchId, mapNumber, g_storedAPIKey);
      if (fileReq != INVALID_HANDLE) {
        LogDebug("Uploading demo to server...");
        SteamWorks_SetHTTPRequestRawPostBodyFromFile(fileReq, "application/octet-stream", filename);
        SteamWorks_SetHTTPCallbacks(fileReq, DemoCallback);
        SteamWorks_SendHTTPRequest(fileReq);
      }
    }

    // Need to store as get5 recycles the configs before the demos finish recording.
    Format(g_storedAPIKey, sizeof(g_storedAPIKey), "");
    Format(g_storedAPIURL, sizeof(g_storedAPIURL), "");
  }
}

public void Get5_OnMatchPaused(const Get5MatchPausedEvent event) {
  char matchId[64];
  char teamString[64];
  char pauseType[4];

  event.GetMatchId(matchId, sizeof(matchId));
  if (event.PauseType == Get5PauseType_Tactical) {
    Format(pauseType, sizeof(pauseType), "Tact");
  } else if (event.PauseType == Get5PauseType_Tech) {
    Format(pauseType, sizeof(pauseType), "Tech");
  }

  Handle req = CreateRequest(k_EHTTPMethodPOST, "match/%s/pause", matchId);
  GetTeamString(event.Team, teamString, sizeof(teamString));
  if (req != INVALID_HANDLE) {
    AddStringParam(req, "pause_type", pauseType);
    AddStringParam(req, "team_paused", teamString);
    SteamWorks_SendHTTPRequest(req);
  }
}

public void Get5_OnMatchUnpaused(const Get5MatchUnpausedEvent event) {
  char matchId[64];
  char teamString[64];
  event.GetMatchId(matchId, sizeof(matchId));

  Handle req = CreateRequest(k_EHTTPMethodPOST, "match/%s/unpause", matchId);
  GetTeamString(event.Team, teamString, sizeof(teamString));
  if (req != INVALID_HANDLE) {
    AddStringParam(req, "team_unpaused", teamString);
    SteamWorks_SendHTTPRequest(req);
  }
}

public Action Command_LoadBackupUrl(int client, int args) {
  bool steamWorksAvailable = LibraryExists("SteamWorks");

  if (!steamWorksAvailable) {
    ReplyToCommand(client,
                   "Cannot load matches from a url without the Rest in PAWN extension running");
  } else {
    char arg[PLATFORM_MAX_PATH];
    if (args >= 1 && GetCmdArgString(arg, sizeof(arg))) {
      LogDebug("Our Backup URL is %s", arg);
      LoadBackupFromUrl(arg);
      return;
    } else {
      ReplyToCommand(client, "Usage: get5_loadbackup_url <url>");
    }
  }
}

public void Get5_OnRoundStart(const Get5RoundStartedEvent event) {
  char matchId[64];
  char backupFile[PLATFORM_MAX_PATH];
  event.GetMatchId(matchId, sizeof(matchId));
  Handle req = CreateRequestNoKey(k_EHTTPMethodPUT, "match/%s/map/%d/round/%d/backup/%s", 
    matchId, event.MapNumber, event.RoundNumber, g_APIKey);
  if (req != INVALID_HANDLE) {
    char backupDirectory[PLATFORM_MAX_PATH];
    GetConVarStringSafe("get5_backup_path", backupDirectory, sizeof(backupDirectory));
    ReplaceString(backupDirectory, sizeof(backupDirectory), "{MATCHID}", matchId);
    Format(backupFile, sizeof(backupFile), "%sget5_backup_match%s_map%d_round%d.cfg", backupDirectory,
           matchId, event.MapNumber, event.RoundNumber);
    SteamWorks_SetHTTPRequestRawPostBodyFromFile(req, "application/octet-stream", backupFile);
    SteamWorks_SendHTTPRequest(req);
  }
  return;
}

public void Get5_OnRoundStatsUpdated(const Get5RoundStatsUpdatedEvent event) {
  if (Get5_GetGameState() == Get5State_Live) {
    char matchId[64];
    event.GetMatchId(matchId, sizeof(matchId));
    UpdateRoundStats(matchId, Get5_GetMapNumber());
  }
}

public void Get5_OnRoundEnd(const Get5RoundEndedEvent event) {
  int roundsPerHalf = GetCvarIntSafe("mp_maxrounds") / 2;
  int roundsPerOTHalf = GetCvarIntSafe("mp_overtime_maxrounds") / 2;

  bool halftimeEnabled = (GetCvarIntSafe("mp_halftime") != 0);

  if (halftimeEnabled) {

      // Regulation halftime. (after round 15)
      if (event.RoundNumber == roundsPerHalf) {
        Get5_MessageToAll("This match has been brought to you by G5API!");
        if (g_EnableSupportMessage.BoolValue) {
          Get5_MessageToAll("Consider supporting @ https://github.com/phlexplexico/G5API !");
        }
      }

      // Now in OT.
      if (event.RoundNumber >= 2 * roundsPerHalf) {
        int otround = event.RoundNumber - 2 * roundsPerHalf;  // round 33 -> round 3, etc.
        // Do side swaps at OT halves (rounds 3, 9, ...)
        if ((otround + roundsPerOTHalf) % (2 * roundsPerOTHalf) == 0) {
          Get5_MessageToAll("This match has been brought to you by G5API!");
          if (g_EnableSupportMessage.BoolValue) {
            Get5_MessageToAll("Consider supporting @ https://github.com/phlexplexico/G5API !");
          }
        }
      }
    }
}

stock bool LoadBackupFromUrl(const char[] url) {
  char cleanedUrl[1024];
  char configPath[PLATFORM_MAX_PATH];
  strcopy(cleanedUrl, sizeof(cleanedUrl), url);
  ReplaceString(cleanedUrl, sizeof(cleanedUrl), "\"", "");
  Format(configPath, sizeof(configPath), "match_restore_remote.cfg"); 
  Handle req = CreateRequestNoKey(k_EHTTPMethodGET, cleanedUrl);
  if (req != INVALID_HANDLE) {
    SteamWorks_WriteHTTPResponseBodyToFile(req, configPath);
    Get5_MessageToAll("Restoring the match from a remote config in 5 seconds.");
    DataPack timerPack;
    CreateDataTimer(5.0, DelayLoadBackup, timerPack, TIMER_FLAG_NO_MAPCHANGE);
    timerPack.WriteString(configPath);
    return true;
  }

  return false;
}

public Action DelayLoadBackup(Handle timer, DataPack pack) {
  char configPath[PLATFORM_MAX_PATH];
  pack.Reset();
  pack.ReadString(configPath, sizeof(configPath));
  // Set API key. This is used as preround start does not have it set yet.
  KeyValues kv = new KeyValues("Backup");
  if (!kv.ImportFromFile(configPath)) {
    LogError("Failed to read backup file \"%s\"", configPath);
    delete kv;
    return Plugin_Stop;
  }
  if (kv.JumpToKey("Match")) {
    if (kv.JumpToKey("cvars")) { 
      kv.GetString("get5_web_api_key", g_APIURL, sizeof(g_APIURL));
    }
    delete kv;
    ServerCommand("get5_loadbackup %s", configPath);
    delete pack;
    return Plugin_Continue;
  } else {
    delete pack;
    Get5_MessageToAll("Failed to load match backup.");
    return Plugin_Stop;
  }
}