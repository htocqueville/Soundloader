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
			with title "Sounddrop"

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
	set updateCmd to ¬
		"cd " & quoted form of repoPath & ¬
		" && echo '⬇️  Pulling latest changes...' && git pull --ff-only" & ¬
		" && echo '' && echo '🔧 Rebuilding app...' && bash " & quoted form of (repoPath & "/setup.sh") & ¬
		" && echo '' && echo '✅ Update complete! Please reopen Sounddrop from /Applications or Spotlight.'" & ¬
		" || echo '' && echo '❌ Update failed. Check the output above and try again.'"
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

	set outputTemplate to musicDir & "music-downloader/{list-name}/{list-position} - {artists} - {title}.{output-ext}"
	set cmd to "source ~/.zshrc 2>/dev/null; source ~/.zprofile 2>/dev/null; " & ¬
		spotdlPath & " --config --user-auth download " & quoted form of playlistURL & ¬
		" --bitrate 320k --format mp3 --threads 4" & ¬
		" --output " & quoted form of outputTemplate & ¬
		"; osascript -e 'display notification \"Spotify download complete\" with title \"Sounddrop\" sound name \"Glass\"'" & ¬
		"; echo ''; echo '✅ Download complete. You can close this window.'"

	tell application "Terminal"
		activate
		do script cmd
	end tell
end handleSpotify


-- ── SoundCloud ────────────────────────────────────────────────────────────────

on handleSoundCloud(scURL)
	set musicDir to POSIX path of (path to music folder)
	set isSet to (scURL contains "/sets/")

	if isSet then
		set outputTemplate to musicDir & "music-downloader/%(playlist_title)s/%(playlist_index)02d - %(uploader)s - %(title)s.%(ext)s"
	else
		set outputTemplate to musicDir & "music-downloader/SoundCloud/%(uploader)s - %(title)s.%(ext)s"
	end if

	set cmd to "source ~/.zshrc 2>/dev/null; source ~/.zprofile 2>/dev/null; " & ¬
		ytdlpPath & ¬
		" --ignore-errors" & ¬
		" --no-overwrites" & ¬
		" --extract-audio --audio-format mp3 --audio-quality 0" & ¬
		" --add-metadata --embed-thumbnail" & ¬
		" --min-sleep-interval 2 --max-sleep-interval 4" & ¬
		" --retries 5" & ¬
		" -o " & quoted form of outputTemplate & ¬
		" " & quoted form of scURL & ¬
		"; osascript -e 'display notification \"SoundCloud download complete\" with title \"Sounddrop\" sound name \"Glass\"'" & ¬
		"; echo ''; echo '✅ Download complete. You can close this window.'"

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
		set outputTemplate to musicDir & "music-downloader/%(playlist_title)s/%(title)s.%(ext)s"
	else
		set outputTemplate to musicDir & "music-downloader/YouTube/%(uploader)s - %(title)s.%(ext)s"
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
	set cmd to "source ~/.zshrc 2>/dev/null; source ~/.zprofile 2>/dev/null; " & ¬
		ytdlpPath & " --extract-audio --audio-format mp3" & ¬
		" --embed-thumbnail" & ¬
		" --parse-metadata \"title:(?P<artist>.+?) [–\\-] (?P<track>.+)\"" & ¬
		" --parse-metadata \"upload_date:(?P<date>\\d{4})\"" & ¬
		" --postprocessor-args \"ffmpeg:-b:a 320k -metadata description= -metadata synopsis= -metadata purl= -metadata comment=\"" & ¬
		" --yes-playlist --no-overwrites --add-metadata" & ¬
		" --cookies-from-browser safari" & ¬
		" -o " & quoted form of outputTemplate & ¬
		" " & quoted form of videoURL & ¬
		"; osascript -e 'display notification \"YouTube download complete\" with title \"Sounddrop\" sound name \"Glass\"'" & ¬
		"; echo ''; echo '✅ Download complete. You can close this window.'"

	tell application "Terminal"
		activate
		do script cmd
	end tell
end handleYouTube
