-- Compile-time values injected by setup.sh
property spotdlPath : "__SPOTDL_PATH__"
property ytdlpPath : "__YTDLP_PATH__"
property repoPath : "__REPO_PATH__"
property currentCommit : "__CURRENT_COMMIT__"
property commitsURL : "__COMMITS_URL__"

on run
	-- ── Auto-update check ──────────────────────────────────────────────────────
	-- Compares the baked-in git SHA against the latest commit on GitHub main.
	-- A push = new SHA = update prompt. No version file to maintain.
	-- curl timeout 3s; all errors caught silently so a network issue never blocks.
	if commitsURL is not "" then
		try
			set apiResult to do shell script "curl -sf --max-time 3 " & quoted form of commitsURL & " | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[\"sha\"]+\"|\"+(d[\"commit\"][\"message\"].split(chr(10))[0])+\"|\"+d[\"commit\"][\"author\"][\"date\"][:10])' 2>/dev/null"
			if apiResult is not "" then
				set AppleScript's text item delimiters to "|"
				set apiParts to text items of apiResult
				set AppleScript's text item delimiters to ""
				set remoteCommit to item 1 of apiParts
				set commitMsg to item 2 of apiParts
				set commitDate to item 3 of apiParts
				if remoteCommit is not currentCommit then
					set updateMsg to "A new update is available!" & return & return & ¬
						"Installed : " & text 1 thru 7 of currentCommit & return & ¬
						"Available : " & text 1 thru 7 of remoteCommit & "  (" & commitDate & ")" & return & ¬
						"            " & quote & commitMsg & quote & return & return & ¬
						"Update now? Opens a Terminal, rebuilds the app automatically."
					set updateChoice to display dialog updateMsg ¬
						buttons {"Later", "Update Now"} default button "Update Now" ¬
						with title "Update Available"
					if button returned of updateChoice is "Update Now" then
						my performUpdate()
						return
					end if
				end if
			end if
		end try
	end if

	-- ── Main dialog ────────────────────────────────────────────────────────────
	try
		set dialogURL to display dialog "Paste a Spotify, YouTube or SoundCloud URL:" ¬
			default answer "" ¬
			buttons {"Cancel", "⚙ Settings", "Download"} ¬
			default button "Download" ¬
			cancel button "Cancel" ¬
			with title "Soundloader"

		set inputURL to text returned of dialogURL
		set clickedBtn to button returned of dialogURL

		if clickedBtn is "⚙ Settings" then
			my showSettings()
			return
		end if

		if inputURL is "" then
			display alert "Error" message "URL cannot be empty." buttons {"OK"} as warning
			return
		end if

		set isSpotify to (inputURL contains "spotify.com")
		set isYouTube to (inputURL contains "youtube.com" or inputURL contains "youtu.be")
		set isSoundCloud to (inputURL contains "soundcloud.com")

		if not isSpotify and not isYouTube and not isSoundCloud then
			display alert "Unsupported URL" ¬
				message "Please enter a Spotify, YouTube or SoundCloud URL." ¬
				buttons {"OK"} as warning
			return
		end if

		if isSpotify then
			my handleSpotify(inputURL)
		else if isSoundCloud then
			my handleSoundCloud(inputURL)
		else
			my handleYouTube(inputURL)
		end if

	on error errorMsg number errorNum
		if errorNum is not -128 then
			display alert "An error occurred" message errorMsg buttons {"OK"} as critical
		end if
	end try
end run


-- ── Update ────────────────────────────────────────────────────────────────────

-- git pull + setup.sh in a Terminal window, then quit so the user reopens
-- the freshly compiled app. The Terminal echoes a clear completion message.
on performUpdate()
	-- Note: the success/failure echoes must be grouped — a bare
	-- `… && echo OK || echo '' && echo FAIL` parses left-to-right as
	-- `(… || echo '') && echo FAIL`, printing FAIL even on success.
	set updateCmd to ¬
		"if cd " & quoted form of repoPath & ¬
		" && echo '⬇️  Pulling latest changes...' && git pull --ff-only" & ¬
		" && echo '' && echo '🔧 Rebuilding app...' && bash " & quoted form of (repoPath & "/setup.sh") & ¬
		"; then echo ''; echo '✅ Update complete! Please reopen Soundloader from /Applications or Spotlight.'" & ¬
		"; else echo ''; echo '❌ Update failed. Check the output above and try again.'; fi"
	tell application "Terminal"
		activate
		do script updateCmd
	end tell
end performUpdate

-- Check for updates on demand (called from Settings). Returns true if an
-- update was found and the user chose to install it.
on checkForUpdates()
	if commitsURL is "" then
		display alert "Update check unavailable" ¬
			message "No GitHub remote is configured. Re-run setup.sh from the project folder to fix this." ¬
			buttons {"OK"} default button "OK"
		return false
	end if
	try
		set apiResult to do shell script "curl -sf --max-time 5 " & quoted form of commitsURL & " | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[\"sha\"]+\"|\"+(d[\"commit\"][\"message\"].split(chr(10))[0])+\"|\"+d[\"commit\"][\"author\"][\"date\"][:10])' 2>/dev/null"
		if apiResult is "" then
			display alert "Update check failed" ¬
				message "Could not reach GitHub. Check your internet connection." ¬
				buttons {"OK"} default button "OK"
			return false
		end if
		set AppleScript's text item delimiters to "|"
		set apiParts to text items of apiResult
		set AppleScript's text item delimiters to ""
		set remoteCommit to item 1 of apiParts
		set commitMsg to item 2 of apiParts
		set commitDate to item 3 of apiParts
		if remoteCommit is currentCommit then
			display alert "You're up to date!" ¬
				message "Commit : " & text 1 thru 7 of currentCommit & return & ¬
				"Date   : " & commitDate ¬
				buttons {"OK"} default button "OK"
			return false
		end if
		set updateMsg to "A new update is available!" & return & return & ¬
			"Installed : " & text 1 thru 7 of currentCommit & return & ¬
			"Available : " & text 1 thru 7 of remoteCommit & "  (" & commitDate & ")" & return & ¬
			"            " & quote & commitMsg & quote & return & return & ¬
			"Update now?"
		set choice to display dialog updateMsg ¬
			buttons {"Cancel", "Update Now"} default button "Update Now" ¬
			with title "Update Available"
		if button returned of choice is "Update Now" then
			my performUpdate()
			return true
		end if
	on error
		display alert "Update check failed" ¬
			message "Could not reach GitHub. Check your internet connection." ¬
			buttons {"OK"} default button "OK"
	end try
	return false
end checkForUpdates


-- ── Settings ──────────────────────────────────────────────────────────────────

on showSettings()
	set homeDir to POSIX path of (path to home folder)
	set configPath to homeDir & ".spotdl/config.json"

	-- Read current client_id for display
	set currentId to ""
	try
		set currentId to do shell script "python3 -c \"import json; d=json.load(open('" & configPath & "')); print(d.get('client_id',''))\" 2>/dev/null"
	end try
	set maskedId to "(not set)"
	if length of currentId > 8 then
		set maskedId to (text 1 thru 8 of currentId) & "••••••••"
	else if currentId is not "" then
		set maskedId to currentId & "••••"
	end if

	set infoMsg to "Spotify Client ID : " & maskedId & return & ¬
		"Commit            : " & text 1 thru 7 of currentCommit

	set settingsChoice to display alert "Settings" ¬
		message infoMsg ¬
		buttons {"Cancel", "Check for Updates", "Edit Spotify Credentials"} ¬
		default button "Edit Spotify Credentials"

	set choiceBtn to button returned of settingsChoice

	if choiceBtn is "Check for Updates" then
		if my checkForUpdates() then return -- user triggered update, bail out

	else if choiceBtn is "Edit Spotify Credentials" then
		open location "https://developer.spotify.com/dashboard"
		display alert "Get your Spotify credentials" ¬
			message "In the Spotify Developer Dashboard:" & return & ¬
			"1. Open (or create) your app" & return & ¬
			"2. Settings → copy Client ID and Client Secret" & return & ¬
			"   (Redirect URIs must include http://127.0.0.1:9900/)" & return & return & ¬
			"Then click OK and enter them below." ¬
			buttons {"OK"} default button "OK"

		set idDialog to display dialog "Spotify Client ID:" ¬
			default answer currentId ¬
			buttons {"Cancel", "Next"} default button "Next" cancel button "Cancel" ¬
			with title "Spotify Credentials — Step 1/2"
		set newClientId to text returned of idDialog

		set secretDialog to display dialog "Spotify Client Secret:" ¬
			default answer "" ¬
			buttons {"Cancel", "Save"} default button "Save" cancel button "Cancel" ¬
			with title "Spotify Credentials — Step 2/2"
		set newClientSecret to text returned of secretDialog

		my saveCredentials(homeDir, configPath, newClientId, newClientSecret)

		display alert "Credentials Saved" ¬
			message "Your Spotify credentials have been updated and the auth cache has been cleared." & return & return & ¬
			"The app will open a browser to re-authenticate on your next Spotify download." ¬
			buttons {"OK"} default button "OK"
	end if
end showSettings


-- ── Credentials ───────────────────────────────────────────────────────────────

on saveCredentials(homeDir, configPath, clientId, clientSecret)
	do shell script "mkdir -p " & quoted form of (homeDir & ".spotdl")
	set pyCode to "import json; d=json.load(open('" & configPath & "')); d['client_id']='" & clientId & "'; d['client_secret']='" & clientSecret & "'; open('" & configPath & "','w').write(json.dumps(d,indent=2))"
	do shell script "python3 -c " & quoted form of pyCode
	do shell script "rm -f " & quoted form of (homeDir & ".spotdl/.spotipy") & "; rm -f " & quoted form of (homeDir & ".cache") & "; rm -f /tmp/.spotipy 2>/dev/null; true"
end saveCredentials


-- ── yt-dlp freshness ──────────────────────────────────────────────────────────
-- Shell snippet (trailing "; ") run before every download: scripts/
-- ytdlp_refresh.py, on spotdl's venv interpreter, keeps both the yt_dlp
-- module spotdl downloads with and the Homebrew yt-dlp binary (SoundCloud /
-- YouTube) current. At most one check a day, exit 0 whatever happens, so it
-- never blocks. An outdated yt-dlp is the one failure that breaks every
-- track at once (YouTube-side changes) — updating is the only fix.

on ytdlpRefreshCmd()
	set AppleScript's text item delimiters to "/"
	set venvPython to ((text items 1 thru -2 of spotdlPath) as text) & "/python3"
	set AppleScript's text item delimiters to ""
	return quoted form of venvPython & " " & quoted form of (repoPath & "/scripts/ytdlp_refresh.py") & "; "
end ytdlpRefreshCmd

-- ── Spotify ───────────────────────────────────────────────────────────────────

on handleSpotify(playlistURL)
	set homeDir to POSIX path of (path to home folder)
	set configPath to homeDir & ".spotdl/config.json"
	set musicDir to POSIX path of (path to music folder)

	set hasCredentials to false
	set defaultId to "5f573c9620494bae87890c0f08a60293"
	try
		set checkCmd to "python3 -c \"import json,sys; d=json.load(open('" & configPath & "')); cid=d.get('client_id',''); cs=d.get('client_secret',''); sys.exit(0 if cid and len(cid)>5 and cs and len(cs)>5 and cid!='" & defaultId & "' else 1)\" 2>/dev/null && echo YES || echo NO"
		if (do shell script checkCmd) is "YES" then set hasCredentials to true
	end try

	if not hasCredentials then
		display alert "Spotify Setup Required" ¬
			message "To download from Spotify, you need a free Spotify Developer account." & return & return & ¬
			"Click 'Open Dashboard' to create an app and get your API credentials." ¬
			buttons {"Open Dashboard"} default button "Open Dashboard"
		open location "https://developer.spotify.com/dashboard"
		display alert "Create a Spotify App" ¬
			message "In the dashboard:" & return & ¬
			"1. Click 'Create app'" & return & ¬
			"2. Fill in any name and description" & return & ¬
			"3. Add both Redirect URIs:" & return & ¬
			"   • http://127.0.0.1:9900/" & return & ¬
			"   • http://127.0.0.1:9900" & return & ¬
			"4. Check 'Web API'" & return & ¬
			"5. Go to Settings → copy Client ID and Client Secret" & return & return & ¬
			"Then click OK and enter your credentials." ¬
			buttons {"OK"} default button "OK"
		set idDialog to display dialog "Enter your Spotify Client ID:" ¬
			default answer "" buttons {"Cancel", "Next"} default button "Next" cancel button "Cancel" ¬
			with title "Spotify Setup — Step 1/2"
		set secretDialog to display dialog "Enter your Spotify Client Secret:" ¬
			default answer "" buttons {"Cancel", "Save & Download"} default button "Save & Download" cancel button "Cancel" ¬
			with title "Spotify Setup — Step 2/2"
		my saveCredentials(homeDir, configPath, text returned of idDialog, text returned of secretDialog)
	end if

	set outputTemplate to musicDir & "Soundloader/{list-name}/{list-position} - {artists} - {title}.{output-ext}"

	-- Derive the Python interpreter inside spotdl's pipx venv (mutagen + spotdl
	-- importable). The pre-sync script reorders/dedupes existing files to match
	-- the current Spotify playlist before spotdl runs, so a re-shuffled playlist
	-- doesn't cause re-downloads under new {list-position} numbers.
	set AppleScript's text item delimiters to "/"
	set spotdlBinDir to (text items 1 thru -2 of spotdlPath) as text
	set AppleScript's text item delimiters to ""
	set spotdlPython to spotdlBinDir & "/python3"
	set syncScript to repoPath & "/scripts/spotify_sync.py"
	set precheckScript to repoPath & "/scripts/spotify_precheck.py"
	set cacheDir to homeDir & ".soundloader/cache"

	-- ── Pre-check (playlists only) ───────────────────────────────────────────
	-- Runs in < 2 s: detects rate limiting and looks for a fresh local cache.
	-- Lets the user choose between fetching fresh data or reusing the cache.
	set useCache to false
	set cacheFile to ""

	if playlistURL contains "/playlist/" then
		-- Extract the playlist ID (e.g. "3ErdJvkPPIKFjpu3gxz0Zw") from the URL.
		set playlistId to do shell script "python3 -c \"import re,sys; m=re.search(r'playlist/([A-Za-z0-9]+)',sys.argv[1]); print(m.group(1) if m else '')\" " & quoted form of playlistURL & " 2>/dev/null"

		set precheckOut to do shell script ¬
			quoted form of spotdlPython & " " & quoted form of precheckScript & ¬
			" --url " & quoted form of playlistURL & ¬
			" --cache-dir " & quoted form of cacheDir & ¬
			" 2>/dev/null" without altering line endings

		-- Parse STATUS|RETRY_AFTER|CACHE_FILE|PLAYLIST_NAME|TRACK_COUNT|CACHE_AGE_HOURS
		set AppleScript's text item delimiters to "|"
		set precheckParts to text items of precheckOut
		set AppleScript's text item delimiters to ""

		set precheckStatus to item 1 of precheckParts
		set retryAfterSec to (item 2 of precheckParts) as integer
		set cachedFilePath to item 3 of precheckParts
		set cachedName to item 4 of precheckParts
		set cachedCount to item 5 of precheckParts
		set cachedAgeH to item 6 of precheckParts

		-- Format the retry-after duration for human display.
		set retryStr to ""
		if retryAfterSec > 0 then
			set rHours to retryAfterSec div 3600
			set rMins to (retryAfterSec mod 3600) div 60
			if rHours > 0 then
				set retryStr to rHours & "h " & rMins & "min"
			else
				set retryStr to rMins & "min"
			end if
		end if

		-- ── Case 1: rate-limited, no cache → hard stop ────────────────────────
		if precheckStatus is "RATE_LIMITED" then
			set rlChoice to display alert "Spotify API Rate Limited" ¬
				message "Tes credentials Spotify sont bloqués pendant encore " & retryStr & "." & return & return & ¬
				"Pour télécharger maintenant :" & return & ¬
				"1. Ouvre le Spotify Developer Dashboard" & return & ¬
				"2. Crée une nouvelle app (2 min)" & return & ¬
				"3. Reviens dans  ⚙ Settings → Edit Spotify Credentials" ¬
				buttons {"Fermer", "Ouvrir Dashboard"} default button "Ouvrir Dashboard" as critical
			if button returned of rlChoice is "Ouvrir Dashboard" then
				open location "https://developer.spotify.com/dashboard"
			end if
			return

		-- ── Case 2: rate-limited, cache available → propose le cache ──────────
		else if precheckStatus is "RATE_LIMITED_CACHE" then
			set rlcChoice to display alert "Spotify API Rate Limited" ¬
				message "L'API Spotify est bloquée encore " & retryStr & "." & return & return & ¬
				"Mais tu as un cache local de " & quote & cachedName & quote & " (" & cachedCount & " titres, " & cachedAgeH & "h)." & return & return & ¬
				"Utiliser le cache pour continuer le download ?" ¬
				buttons {"Annuler", "Ouvrir Dashboard", "Utiliser le cache"} ¬
				default button "Utiliser le cache" as warning
			set rlcBtn to button returned of rlcChoice
			if rlcBtn is "Annuler" then return
			if rlcBtn is "Ouvrir Dashboard" then
				open location "https://developer.spotify.com/dashboard"
				return
			end if
			-- "Utiliser le cache"
			set useCache to true
			set cacheFile to cachedFilePath

		-- ── Case 3: API OK, fresh cache available → laisser le choix ──────────
		else if precheckStatus is "OK_CACHE" then
			set cacheChoice to button returned of (display dialog ¬
				"Cache disponible pour " & quote & cachedName & quote & " (" & cachedCount & " titres, mis à jour il y a " & cachedAgeH & "h)." & return & return & ¬
				"Utiliser le cache (rapide, 0 appel Spotify) ou refaire le fetch ?" ¬
				buttons {"Annuler", "Refaire le fetch", "Utiliser le cache"} ¬
				default button "Utiliser le cache" cancel button "Annuler" ¬
				with title "Cache disponible")
			if cacheChoice is "Utiliser le cache" then
				set useCache to true
				set cacheFile to cachedFilePath
			end if
			-- "Refaire le fetch" → useCache reste false, fetch normal
		end if
		-- Case 4: precheckStatus is "OK" (no cache) → proceed silently
	end if

	-- ── Build commands ────────────────────────────────────────────────────────
	set syncCmd to ""
	set dlTarget to quoted form of playlistURL  -- default: download by URL

	if playlistURL contains "/playlist/" then
		if useCache then
			-- Use cached .spotdl file: sync reconciles local files, spotdl downloads
			-- only missing tracks — no Spotify API call in either step.
			-- IMPORTANT: spotdl reads a .spotdl save file when it is passed AS THE
			-- QUERY (e.g. `spotdl download cache.spotdl`). The --save-file flag is
			-- for WRITING (e.g. `spotdl save`), not for input.
			set syncCmd to quoted form of spotdlPython & " " & quoted form of syncScript & ¬
				" --url " & quoted form of playlistURL & ¬
				" --output-base " & quoted form of (musicDir & "Soundloader") & ¬
				" --spotdl " & quoted form of spotdlPath & ¬
				" --cache-file " & quoted form of cacheFile & "; "
			set dlTarget to quoted form of cacheFile
		else
			-- Fresh fetch: sync saves result to cache for next time.
			set syncCmd to quoted form of spotdlPython & " " & quoted form of syncScript & ¬
				" --url " & quoted form of playlistURL & ¬
				" --output-base " & quoted form of (musicDir & "Soundloader") & ¬
				" --spotdl " & quoted form of spotdlPath & ¬
				" --cache-dir " & quoted form of cacheDir & "; "
		end if
	end if

	-- Download through the retry driver: it runs spotdl, verifies on disk
	-- which tracks are actually present (same file-name logic spotdl uses),
	-- and re-runs spotdl from the local .spotdl data (no Spotify re-fetch)
	-- until everything is there or the attempt budget is spent.
	-- Exit 0 = all tracks verified on disk → success notification;
	-- anything else → failure notification, missing tracks listed in Terminal.
	set downloadScript to repoPath & "/scripts/spotify_download.py"
	set dlCmd to quoted form of spotdlPython & " " & quoted form of downloadScript & ¬
		" --spotdl " & quoted form of spotdlPath & ¬
		" --target " & dlTarget & ¬
		" --cache-dir " & quoted form of cacheDir & ¬
		" --output " & quoted form of outputTemplate & ¬
		" --format mp3 --attempts 3" & ¬
		" -- --config --user-auth --bitrate 320k --threads 4 --scan-for-songs"

	set cmd to "source ~/.zshrc 2>/dev/null; source ~/.zprofile 2>/dev/null; " & ¬
		my ytdlpRefreshCmd() & ¬
		syncCmd & ¬
		"if " & dlCmd & ¬
		"; then osascript -e 'display notification \"Spotify download complete\" with title \"Soundloader\" sound name \"Glass\"'" & ¬
		"; echo ''; echo '✅ Download complete. You can close this window.'" & ¬
		"; else osascript -e 'display notification \"Download finished — some tracks are missing\" with title \"Soundloader\" sound name \"Basso\"'" & ¬
		"; echo ''; echo '⚠️  Some tracks could not be downloaded — see the list above.'; fi"

	tell application "Terminal"
		activate
		do script cmd
	end tell
end handleSpotify


-- ── SoundCloud ────────────────────────────────────────────────────────────────

on handleSoundCloud(scURL)
	set musicDir to POSIX path of (path to music folder)

	-- Detect playlists (sets) by asking yt-dlp instead of sniffing the URL:
	-- short share links (on.soundcloud.com/…) don't contain "/sets/", so URL
	-- sniffing sends whole playlists into the flat SoundCloud/ folder.
	-- The probe prints the playlist title of the first entry ("NA" for a
	-- single track) in a couple of seconds, without downloading anything.
	set isSet to false
	try
		set probeTitle to do shell script ytdlpPath & ¬
			" --flat-playlist --playlist-items 1 --no-warnings --print playlist_title " & ¬
			quoted form of scURL & " 2>/dev/null | head -1"
		if probeTitle is not "" and probeTitle is not "NA" then
			set isSet to true
		else if probeTitle is "" then
			-- Probe failed (network hiccup): fall back to URL sniffing.
			set isSet to (scURL contains "/sets/")
		end if
	on error
		set isSet to (scURL contains "/sets/")
	end try

	if isSet then
		-- Same layout as Spotify playlists: one folder per playlist, named
		-- after it — so a playlist with the same name on both platforms
		-- lands in the same folder.
		set outputTemplate to musicDir & "Soundloader/%(playlist_title)s/%(playlist_index)02d - %(uploader)s - %(title)s.%(ext)s"
	else
		set outputTemplate to musicDir & "Soundloader/SoundCloud/%(uploader)s - %(title)s.%(ext)s"
	end if

	-- ytdlp_retry.sh re-runs yt-dlp (up to 3 attempts) while items fail;
	-- a temp --download-archive makes retries skip what already succeeded.
	-- Success notification only when every item is downloaded (exit 0).
	set retryHelper to repoPath & "/scripts/ytdlp_retry.sh"
	set cmd to "source ~/.zshrc 2>/dev/null; source ~/.zprofile 2>/dev/null; " & ¬
		my ytdlpRefreshCmd() & ¬
		"if bash " & quoted form of retryHelper & " 3 " & ytdlpPath & ¬
		" --ignore-errors" & ¬
		" --no-overwrites" & ¬
		" --extract-audio --audio-format mp3 --audio-quality 0" & ¬
		" --add-metadata --embed-thumbnail" & ¬
		" --min-sleep-interval 2 --max-sleep-interval 4" & ¬
		" --retries 5" & ¬
		" -o " & quoted form of outputTemplate & ¬
		" " & quoted form of scURL & ¬
		"; then osascript -e 'display notification \"SoundCloud download complete\" with title \"Soundloader\" sound name \"Glass\"'" & ¬
		"; echo ''; echo '✅ Download complete. You can close this window.'" & ¬
		"; else osascript -e 'display notification \"Download finished — some items are missing\" with title \"Soundloader\" sound name \"Basso\"'" & ¬
		"; echo ''; echo '⚠️  Some items could not be downloaded — see the output above.'; fi"

	tell application "Terminal"
		activate
		do script cmd
	end tell
end handleSoundCloud


-- ── YouTube ───────────────────────────────────────────────────────────────────

on handleYouTube(videoURL)
	set musicDir to POSIX path of (path to music folder)
	set isPlaylist to (videoURL contains "list=")

	if isPlaylist then
		set outputTemplate to musicDir & "Soundloader/%(playlist_title)s/%(title)s.%(ext)s"
	else
		set outputTemplate to musicDir & "Soundloader/YouTube/%(uploader)s - %(title)s.%(ext)s"
	end if

	-- Metadata cleanup flags:
	--
	-- --embed-thumbnail          : embed cover art (YouTube thumbnail) into the MP3
	-- --parse-metadata (1st)     : try to split "Artist – Title" or "Artist - Title" from
	--                              the video title into proper artist + track fields.
	--                              Only fires when the pattern matches; harmless otherwise.
	-- --parse-metadata (2nd)     : extract the 4-digit year from upload_date (YYYYMMDD)
	--                              so the date tag is "2023" not "20230214".
	-- --postprocessor-args       : (a) set audio bitrate 320k
	--                              (b) strip YouTube-specific junk tags that pollute
	--                                  music players: description, synopsis, purl, comment
	-- ytdlp_retry.sh re-runs yt-dlp (up to 3 attempts) while items fail;
	-- a temp --download-archive makes retries skip what already succeeded.
	-- Success notification only when every item is downloaded (exit 0).
	set retryHelper to repoPath & "/scripts/ytdlp_retry.sh"
	set cmd to "source ~/.zshrc 2>/dev/null; source ~/.zprofile 2>/dev/null; " & ¬
		my ytdlpRefreshCmd() & ¬
		"if bash " & quoted form of retryHelper & " 3 " & ytdlpPath & ¬
		" --extract-audio --audio-format mp3" & ¬
		" --embed-thumbnail" & ¬
		" --parse-metadata \"title:(?P<artist>.+?) [–\\-] (?P<track>.+)\"" & ¬
		" --parse-metadata \"upload_date:(?P<date>\\d{4})\"" & ¬
		" --postprocessor-args \"ffmpeg:-b:a 320k -metadata description= -metadata synopsis= -metadata purl= -metadata comment=\"" & ¬
		" --yes-playlist --no-overwrites --add-metadata" & ¬
		" --cookies-from-browser safari" & ¬
		" -o " & quoted form of outputTemplate & ¬
		" " & quoted form of videoURL & ¬
		"; then osascript -e 'display notification \"YouTube download complete\" with title \"Soundloader\" sound name \"Glass\"'" & ¬
		"; echo ''; echo '✅ Download complete. You can close this window.'" & ¬
		"; else osascript -e 'display notification \"Download finished — some items are missing\" with title \"Soundloader\" sound name \"Basso\"'" & ¬
		"; echo ''; echo '⚠️  Some items could not be downloaded — see the output above.'; fi"

	tell application "Terminal"
		activate
		do script cmd
	end tell
end handleYouTube
