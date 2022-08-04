/**
 * =============================================================================
 * Get5 Stats (G5WS)
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

#include <ripext>

#define PLUGIN_VERSION "3.1.2"

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
  g_UseSVGCvar = CreateConVar("get5_use_svg", "0", "support svg team logos");
  HookConVarChange(g_UseSVGCvar, LogoBasePathChanged);
  g_LogoBasePath = g_UseSVGCvar.BoolValue ? LOGO_DIR : LEGACY_LOGO_DIR;

  g_EnableDemoUpload = CreateConVar("get5_upload_demos", "1", "Upload demo on post match.");

  g_EnableSupportMessage = CreateConVar("get5_api_support_message", "1", "Enable a dono message every half time.");

  g_APIKeyCvar =
      CreateConVar("get5_web_api_key", "", "Match API key, this is automatically set through rcon", FCVAR_DONTRECORD);
  HookConVarChange(g_APIKeyCvar, ApiInfoChanged);

  g_APIURLCvar = CreateConVar("get5_web_api_url", "", "URL the get5 api is hosted at.", FCVAR_DONTRECORD);

  HookConVarChange(g_APIURLCvar, ApiInfoChanged);

  RegConsoleCmd("get5_web_available", Command_Available);

  RegAdminCmd("get5_loadbackup_url", Command_LoadBackupUrl, ADMFLAG_CHANGEMAP,
             "Loads a get5 match backup from a URL.");
}

public Action Command_Available(int client, int args) {
  char versionString[64] = "unknown";
  ConVar versionCvar = FindConVar("get5_version");
  if (versionCvar != null) {
    versionCvar.GetString(versionString, sizeof(versionString));
  }

  JSONObject json = new JSONObject();

  json.SetInt("gamestate", view_as<int>(Get5_GetGameState()));
  json.SetInt("available", 1);
  json.SetString("plugin_version", versionString);

  char buffer[256];
  json.ToString(buffer, sizeof(buffer), true);
  ReplyToCommand(client, buffer);

  delete json;

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

static HTTPRequest CreateRequest(const char[] apiMethod, any:...) {
  char url[1024];
  if (StrEqual(g_APIKey, "")) {
    // Not using a web interface.
    return null;
  }
  Format(url, sizeof(url), "%s%s", g_APIURL, apiMethod);
  LogDebug("Our URL is: %s", url);
  char formattedUrl[1024];
  VFormat(formattedUrl, sizeof(formattedUrl), url, 2);

  LogDebug("Trying to create request to url %s", formattedUrl);

  HTTPRequest req = new HTTPRequest(formattedUrl);
  req.SetHeader("Transfer-Encoding", "");
  if (req == INVALID_HANDLE) {
    LogError("Failed to create request to %s", formattedUrl);
    return null;
  } else {
    return req;
  }
}

static HTTPRequest CreateCustomRequest(const char[] oldUrl, any:...) {
  char url[1024];
  Format(url, sizeof(url), "%s", oldUrl);
  LogDebug("Our URL is: %s", url);
  char formattedUrl[1024];
  VFormat(formattedUrl, sizeof(formattedUrl), url, 2);

  LogDebug("Trying to create request to url %s", formattedUrl);

  HTTPRequest req = new HTTPRequest(formattedUrl);
  if (req == INVALID_HANDLE) {
    LogError("Failed to create request to %s", formattedUrl);
    return null;
  } else {
    return req;
  }
}

static HTTPRequest CreateDemoRequest(const char[] apiMethod, any:...) {
  char url[1024];

  // Check here to avoid leaks from not deleteing req handle.
  if (StrEqual(g_storedAPIKey, "")) {
    // Not using a web interface.
    return null;
  }

  Format(url, sizeof(url), "%s%s", g_storedAPIURL, apiMethod);
  LogDebug("Our URL is: %s", url);
  char formattedUrl[1024];
  VFormat(formattedUrl, sizeof(formattedUrl), url, 2);

  LogDebug("Trying to create request to url %s", formattedUrl);

  HTTPRequest req = new HTTPRequest(formattedUrl);
  if (req == INVALID_HANDLE) {
    LogError("Failed to create request to %s", formattedUrl);
    return null;
  } else {
    return req;
  }
}

public void RequestCallback(HTTPResponse response, any value) {
    char sData[1024];
    if (response.Status == HTTPStatus_InternalServerError) {
        LogError("[ERR] API request failed, HTTP status code: %d", response.Status);
        response.Data.ToString(sData, sizeof(sData), JSON_INDENT(4));
        LogError("[ERR] Response:\n%s", sData);
        return;
    } 
}

void OnDemoUploaded(HTTPStatus status, any value)
{
  if (status != HTTPStatus_OK) {
      LogError("[ERR] Demo request failed, HTTP status code: %d", status);
      return;
  }
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

  char logoPath[PLATFORM_MAX_PATH];
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
    HTTPRequest req =  CreateRequest(endPoint, logo);

    if (req == null) {
      return;
    }
    req.DownloadFile(logoPath, GenericCallback);
    DataPack logoPack = CreateDataPack();
    logoPack.WriteString(logo);
    CreateTimer(2.0, AddLogoToDownloadTable, logoPack, TIMER_FLAG_NO_MAPCHANGE);
    LogMessage("Saved logo for %s at %s", logo, logoPath);
  }
}

public Action AddLogoToDownloadTable(Handle timer, DataPack pack) {
  char logoName[PLATFORM_MAX_PATH + 1];
  pack.Reset();
  pack.ReadString(logoName, sizeof(logoName));
  if (StrEqual(logoName, ""))
    return;

  
  char logoPath[PLATFORM_MAX_PATH + 1];
  Format(logoPath, sizeof(logoPath), "materials/panorama/images/tournaments/teams/%s.svg", logoName);
  if (FileExists(logoPath)) {
    LogDebug("Adding file %s to download table", logoName);
    AddFileToDownloadsTable(logoPath);
  } else {
    Format(logoPath, sizeof(logoPath), "resource/flash/econ/tournaments/teams/%s.png", logoName);
    if (FileExists(logoPath)) {
      LogDebug("Adding file %s to download table", logoName);
      AddFileToDownloadsTable(logoPath);
    } else {
      LogError("Error in locating file %s. Please ensure the file exists on your game server, in either of the team logo directories.", logoName);
    }
  }
}

public void GenericCallback(HTTPStatus status, any value) {
  if (status != HTTPStatus_OK) {
    LogError("Request failed, status code = %d", status);
    return;
  }
  return;
}

public void Get5_OnGoingLive(const Get5GoingLiveEvent event) {
  char mapName[64];
  GetCurrentMap(mapName, sizeof(mapName));

  char matchId[64];
  event.GetMatchId(matchId, sizeof(matchId));

  HTTPRequest req = CreateRequest("match/%s/map/%d/start", matchId, event.MapNumber);
  JSONObject mtchDetail = new JSONObject();
  if (req != null) {
    mtchDetail.SetString("key", g_APIKey);
    mtchDetail.SetString("mapname", mapName);
    req.Post(mtchDetail, RequestCallback);
  }
  // Store Cvar since it gets reset after match finishes?
  if (g_EnableDemoUpload.BoolValue) {
    Format(g_storedAPIKey, sizeof(g_storedAPIKey), g_APIKey);
    Format(g_storedAPIURL, sizeof(g_storedAPIURL), g_APIURL);
  }
  Get5_AddLiveCvar("get5_web_api_key", g_APIKey);
  Get5_AddLiveCvar("get5_web_api_url", g_APIURL);
  delete mtchDetail;
}

public void UpdateRoundStats(const char[] matchId, int mapNumber) {
  int team1Score = CS_GetTeamScore(Get5_Get5TeamToCSTeam(Get5Team_1));
  int team2Score = CS_GetTeamScore(Get5_Get5TeamToCSTeam(Get5Team_2));

  HTTPRequest req = CreateRequest("match/%s/map/%d/update", matchId, mapNumber);
  JSONObject rndStat = new JSONObject();
  if (req != null) {
    rndStat.SetString("key", g_APIKey);
    rndStat.SetInt("team1score", team1Score);
    rndStat.SetInt("team2score", team2Score);
    req.Post(rndStat, RequestCallback);
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
  delete rndStat;
}

public void Get5_OnMapResult(const Get5MapResultEvent event) {
  char matchId[64];
  char winnerString[64];
  
  event.GetMatchId(matchId, sizeof(matchId));
  GetTeamString(event.Winner.Team, winnerString, sizeof(winnerString));

  HTTPRequest req = CreateRequest("match/%s/map/%d/finish", matchId, event.MapNumber);
  JSONObject mtchRes = new JSONObject();
  bool isCancelled = StrEqual(winnerString, "none", false);
  if (req != null && event.MapNumber > -1 && !isCancelled) {
    mtchRes.SetString("key", g_APIKey);
    mtchRes.SetInt("team1score", event.Team1Score);
    mtchRes.SetInt("team2score", event.Team2Score);
    mtchRes.SetString("winner", winnerString);
    req.Post(mtchRes, RequestCallback);
  }
  delete mtchRes;
}

public void UpdatePlayerStats(const char[] matchId, KeyValues kv, Get5Team team) {
  char name[MAX_NAME_LENGTH];
  char auth[AUTH_LENGTH];
  int clientNum;
  int mapNumber = Get5_GetMapNumber();

  if (kv.GotoFirstSubKey()) {
    JSONObject pStat = new JSONObject();
    pStat.SetString("key", g_APIKey);
    do {
      kv.GetSectionName(auth, sizeof(auth));
      clientNum = AuthToClient(auth);
      kv.GetString("name", name, sizeof(name));
      char teamString[16];
      GetTeamString(team, teamString, sizeof(teamString));

      HTTPRequest req = CreateRequest("match/%s/map/%d/player/%s/update", matchId,
                                 mapNumber, auth);
      if (req != null && (clientNum > 0 && !IsClientCoaching(clientNum))) {
        pStat.SetString("team", teamString);
        pStat.SetString("name", name);
        pStat.SetInt(STAT_KILLS, kv.GetNum(STAT_KILLS));
        pStat.SetInt(STAT_DEATHS, kv.GetNum(STAT_DEATHS));
        pStat.SetInt(STAT_ASSISTS, kv.GetNum(STAT_ASSISTS));
        pStat.SetInt(STAT_FLASHBANG_ASSISTS, kv.GetNum(STAT_FLASHBANG_ASSISTS));
        pStat.SetInt(STAT_TEAMKILLS, kv.GetNum(STAT_TEAMKILLS));
        pStat.SetInt(STAT_SUICIDES, kv.GetNum(STAT_SUICIDES));
        pStat.SetInt(STAT_DAMAGE, kv.GetNum(STAT_DAMAGE));
        pStat.SetInt(STAT_HEADSHOT_KILLS, kv.GetNum(STAT_HEADSHOT_KILLS));
        pStat.SetInt(STAT_ROUNDSPLAYED, kv.GetNum(STAT_ROUNDSPLAYED));
        pStat.SetInt(STAT_BOMBPLANTS, kv.GetNum(STAT_BOMBPLANTS));
        pStat.SetInt(STAT_BOMBDEFUSES, kv.GetNum(STAT_BOMBDEFUSES));
        pStat.SetInt(STAT_1K, kv.GetNum(STAT_1K));
        pStat.SetInt(STAT_2K, kv.GetNum(STAT_2K));
        pStat.SetInt(STAT_3K, kv.GetNum(STAT_3K));
        pStat.SetInt(STAT_4K, kv.GetNum(STAT_4K));
        pStat.SetInt(STAT_5K, kv.GetNum(STAT_5K));
        pStat.SetInt(STAT_V1, kv.GetNum(STAT_V1));
        pStat.SetInt(STAT_V2, kv.GetNum(STAT_V2));
        pStat.SetInt(STAT_V3, kv.GetNum(STAT_V3));
        pStat.SetInt(STAT_V4, kv.GetNum(STAT_V4));
        pStat.SetInt(STAT_V5, kv.GetNum(STAT_V5));
        pStat.SetInt(STAT_FIRSTKILL_T, kv.GetNum(STAT_FIRSTKILL_T));
        pStat.SetInt(STAT_FIRSTKILL_CT, kv.GetNum(STAT_FIRSTKILL_CT));
        pStat.SetInt(STAT_FIRSTDEATH_T, kv.GetNum(STAT_FIRSTDEATH_T));
        pStat.SetInt(STAT_FIRSTDEATH_CT, kv.GetNum(STAT_FIRSTDEATH_CT));
        pStat.SetInt(STAT_TRADEKILL, kv.GetNum(STAT_TRADEKILL));
        pStat.SetInt(STAT_KAST, kv.GetNum(STAT_KAST));
        pStat.SetInt(STAT_CONTRIBUTION_SCORE, kv.GetNum(STAT_CONTRIBUTION_SCORE));
        pStat.SetInt(STAT_MVP, kv.GetNum(STAT_MVP));
        pStat.SetInt(STAT_UTILITY_DAMAGE, kv.GetNum(STAT_UTILITY_DAMAGE));
        pStat.SetInt(STAT_KNIFE_KILLS, kv.GetNum(STAT_KNIFE_KILLS));
        pStat.SetInt(STAT_ENEMIES_FLASHED, kv.GetNum(STAT_ENEMIES_FLASHED));
        pStat.SetInt(STAT_FRIENDLIES_FLASHED, kv.GetNum(STAT_FRIENDLIES_FLASHED));
        req.Post(pStat, RequestCallback);
      }
    } while (kv.GotoNextKey());
    kv.GoBack();
    delete pStat;
  } 
}

// New Feat: Add in additional info on what killed a user. To be used with sockets?
/*public void Get5_OnPlayerDeath(const Get5PlayerDeathEvent event) {
  char matchId[64];
  char attackerSteamId[AUTH_LENGTH];
  char attackerName[MAX_NAME_LENGTH];
  char victimSteamId[AUTH_LENGTH];
  char victimName[MAX_NAME_LENGTH];
  char assisterSteamId[AUTH_LENGTH];
  char assisterName[MAX_NAME_LENGTH];
  char weaponName[MAX_NAME_LENGTH];
  int mapNumber = Get5_GetMapNumber();
  int clientNum;
  Get5AssisterObject possibleAssister;
  if (event.HasAttacker()) {
    event.Attacker.GetSteamId(attackerSteamId, sizeof(attackerSteamId));
  }
  event.Player.GetSteamId(victimSteamId, sizeof(victimSteamId));
  if (event.HasAssist()) {
    possibleAssister = event.Assist;
    possibleAssister.Player.GetSteamId(assisterSteamId, sizeof(assisterSteamId));
  }
  // Collect names to avoid contacting Steam on API side.
  KeyValues kv = new KeyValues("Stats");
  Get5_GetMatchStats(kv);
  char mapKey[32];
  Format(mapKey, sizeof(mapKey), "map%d", mapNumber);
  kv.JumpToKey(mapKey);
  if (!strcmp(attackerSteamId, "", false) && kv.GotoFirstSubKey()) {
    kv.JumpToKey(attackerSteamId);
    kv.GetString("name", attackerName, sizeof(attackerName));
    kv.GoBack();
    kv.JumpToKey(victimSteamId);
    kv.GetString("name", victimName, sizeof(victimName));
    kv.GoBack();
    if (event.HasAssist()) {
      kv.JumpToKey(assisterSteamId);
      kv.GetString("name", assisterName, sizeof(assisterName));
    }
  }
  delete kv;

  event.GetMatchId(matchId, sizeof(matchId));
  JSONObject advancedStats = new JSONObject();
  clientNum = AuthToClient(attackerSteamId);

  HTTPRequest req = CreateRequest("match/%s/map/%d/player/%s/extras/update", matchId,
                                 mapNumber, attackerSteamId);
  if (req != null && (clientNum > 0 && !IsClientCoaching(clientNum))) {
    event.Weapon.GetWeaponName(weaponName, sizeof(weaponName));
    advancedStats.SetString("key", g_APIKey);
    advancedStats.SetInt("mapNumber", mapNumber);
    advancedStats.SetString("attackerSteamId", attackerSteamId);
    advancedStats.SetString("attackerName", attackerName);
    advancedStats.SetString("victimSteamId", victimSteamId);
    advancedStats.SetString("victimName", victimName);
    advancedStats.SetInt("roundTime", event.RoundTime);
    advancedStats.SetString("weaponUsed", weaponName);
    advancedStats.SetBool("isHeadshot", event.Headshot);
    advancedStats.SetBool("isFriendlyFire", event.FriendlyFire);
    advancedStats.SetBool("isThruSmoke", event.ThruSmoke);
    advancedStats.SetBool("isNoScope", event.NoScope);
    advancedStats.SetBool("isAttackerBlind", event.AttackerBlind);
    advancedStats.SetBool("isSuicide", event.Suicide);
    advancedStats.SetInt("isPenetrated", event.Penetrated);
    if (event.HasAssist()) {
      advancedStats.SetString("assistedByName", assisterName);
      advancedStats.SetString("assistedBySteamId", assisterSteamId);
      advancedStats.SetBool("isAssistedByFriendlyFire", possibleAssister.FriendlyFire);
      advancedStats.SetBool("isAssistedByFlash", possibleAssister.FlashAssist);
    }
    req.Post(advancedStats, RequestCallback);
  }
  delete advancedStats;
}*/

public void Get5_OnMapVetoed(const Get5MapVetoedEvent event){
  char matchId[64];
  char teamString[64];
  char mapName[64];
  event.GetMatchId(matchId, sizeof(matchId));
  event.GetMapName(mapName, sizeof(mapName));
  GetTeamString(event.Team, teamString, sizeof(teamString));
  
  LogDebug("Map Veto START team %s map vetoed %s", event.Team, mapName);
  HTTPRequest req = CreateRequest("match/%s/vetoUpdate", matchId);
  JSONObject vetoData = new JSONObject();
  if (req != null) {
    vetoData.SetString("key", g_APIKey);
    vetoData.SetString("map", mapName);
    vetoData.SetString("teamString", teamString);
    vetoData.SetString("pick_or_veto", "ban");  
    req.Post(vetoData, RequestCallback);
  }
  LogDebug("Accepted Map Veto for team %s.", teamString);
  delete vetoData;
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
  HTTPRequest req = CreateRequest("match/%s/vetoSideUpdate", matchId);
  JSONObject vetoSideData = new JSONObject();
  if (event.Side == Get5Side_CT) {
    Format(charSide, sizeof(charSide), "CT");
  } else if (event.Side == Get5Side_T) {
    Format(charSide, sizeof(charSide), "T");
  } else {
    Format(charSide, sizeof(charSide), "UNK");
  }
  if (req != null) {
    vetoSideData.SetString("key", g_APIKey);
    vetoSideData.SetString("map", mapName);
    vetoSideData.SetString("teamString", teamString);
    vetoSideData.SetString("side", charSide);
    req.Post(vetoSideData, RequestCallback);
  }
  LogDebug("Accepted side picked for map %s.", mapName);
  delete vetoSideData;
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
    HTTPRequest req = CreateDemoRequest("match/%s/map/%d/demo", matchId, mapNumber);
    JSONObject demoJSON = new JSONObject();
    LogDebug("Our api url: %s", g_storedAPIURL);
    // Send demo file name to store in database to show users at end of match.
    if (req != null) {
      demoJSON.SetString("key", g_storedAPIKey);
      LogDebug("Our demo string: %s", filename);
      demoJSON.SetString("demoFile", filename);
      req.Post(demoJSON, RequestCallback);
      req = CreateDemoRequest("match/%s/map/%d/demo/upload/%s", matchId, mapNumber, g_storedAPIKey);
      if (req != null) {
        LogDebug("Uploading demo to server...");
        req.UploadFile(filename, OnDemoUploaded);
        LogDebug("COMPLETE!");
      }
    }

    // Need to store as get5 recycles the configs before the demos finish recording.
    Format(g_storedAPIKey, sizeof(g_storedAPIKey), "");
    Format(g_storedAPIURL, sizeof(g_storedAPIURL), "");
    delete demoJSON;
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
  LogDebug("Map Pick START team %s map vetoed %s", event.Team, mapName);
  HTTPRequest req = CreateRequest("match/%s/vetoUpdate", matchId);
  JSONObject vetoData = new JSONObject();
  if (req != null) {
    vetoData.SetString("key", g_APIKey);
    vetoData.SetString("map", mapName);
    vetoData.SetString("teamString", teamString);
    vetoData.SetString("pick_or_veto", "pick");
    req.Post(vetoData, RequestCallback);
  }
  LogDebug("Accepted Map Pick.");
  delete vetoData;
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

  HTTPRequest req = CreateRequest("match/%s/finish", matchId);
  JSONObject seriesRes = new JSONObject();
  // Need to check that we are indeed a best of two match as well.
  // This has been a source of double sending match results and producing errors.
  // So we really need to check if we are in an edge case BO2 where a score is 1-1.
  if (req != null && (event.Team1SeriesScore == event.Team2SeriesScore || !isCancelled)) {
    seriesRes.SetString("key", g_APIKey);
    seriesRes.SetString("winner", winnerString);
    seriesRes.SetInt("team1score", event.Team1SeriesScore);
    seriesRes.SetInt("team2score", event.Team2SeriesScore);
    seriesRes.SetInt("forfeit", forfeit);
    req.Post(seriesRes, RequestCallback);
  } else if (req != null && (forfeit && isCancelled && timeToStartCvar.IntValue > 0)) {
    seriesRes.SetString("key", g_APIKey);
    seriesRes.SetString("winner", winnerString);
    seriesRes.SetInt("team1score", event.Team1SeriesScore);
    seriesRes.SetInt("team2score", event.Team2SeriesScore);
    seriesRes.SetInt("forfeit", forfeit);
    req.Post(seriesRes, RequestCallback);
  }
  g_APIKeyCvar.SetString("");
  delete seriesRes;
}

public void Get5_OnRoundStatsUpdated(const Get5RoundStatsUpdatedEvent event) {
  if (Get5_GetGameState() == Get5State_Live) {
    char matchId[64];
    event.GetMatchId(matchId, sizeof(matchId));
    UpdateRoundStats(matchId, Get5_GetMapNumber());
  }
}

public void Get5_OnMatchPaused(const Get5MatchPausedEvent event) {
  char matchId[64];
  char teamString[64];
  char pauseType[4];

  if (event.PauseType == Get5PauseType_Tactical) {
    Format(pauseType, sizeof(pauseType), "Tact");
  } else if (event.PauseType == Get5PauseType_Tech) {
    Format(pauseType, sizeof(pauseType), "Tech");
  }
  HTTPRequest req = CreateRequest("match/%s/pause", matchId);
  JSONObject matchPause = new JSONObject();
  GetTeamString(event.Team, teamString, sizeof(teamString));
  if (req != null) {
    matchPause.SetString("key", g_APIKey);
    matchPause.SetString("pause_type", pauseType);
    matchPause.SetString("team_paused", teamString);
    req.Post(matchPause, RequestCallback);
  }
  delete matchPause;
}

public void Get5_OnMatchUnpaused(const Get5MatchUnpausedEvent event) {
  char matchId[64];
  char teamString[64];
  event.GetMatchId(matchId, sizeof(matchId));

  HTTPRequest req = CreateRequest("match/%s/unpause", matchId);
  JSONObject matchUnpause = new JSONObject();
  GetTeamString(event.Team, teamString, sizeof(teamString));
  if (req != null) {
    matchUnpause.SetString("key", g_APIKey);
    matchUnpause.SetString("team_unpaused", teamString);
    req.Post(matchUnpause, RequestCallback);
  }
  delete matchUnpause;
}


public Action Command_LoadBackupUrl(int client, int args) {
  bool ripExtAvailable = LibraryExists("ripext");

  if (!ripExtAvailable) {
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
  HTTPRequest req = CreateRequest("match/%s/map/%d/round/%d/backup/%s", 
    matchId, event.MapNumber, event.RoundNumber, g_APIKey);
  if (req != null) {
    char backupDirectory[PLATFORM_MAX_PATH];
    GetConVarStringSafe("get5_backup_path", backupDirectory, sizeof(backupDirectory));
    ReplaceString(backupDirectory, sizeof(backupDirectory), "{MATCHID}", matchId);
    Format(backupFile, sizeof(backupFile), "%sget5_backup_match%s_map%d_round%d.cfg", backupDirectory,
           matchId, event.MapNumber, event.RoundNumber);
    LogDebug("Uploading backup %s to server.", backupFile);
    req.UploadFile(backupFile, GenericCallback);
    LogDebug("COMPLETE!");
  }
  return;
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
  HTTPRequest req = CreateCustomRequest(cleanedUrl);
  if (req == INVALID_HANDLE) {
    return false;
  } else {
    req.DownloadFile(configPath, GenericCallback);
    Get5_MessageToAll("Restoring the match from a remote config in 5 seconds.");
    DataPack timerPack;
    CreateDataTimer(5.0, DelayLoadBackup, timerPack, TIMER_FLAG_NO_MAPCHANGE);
    timerPack.WriteString(configPath);
    return true;
  }
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