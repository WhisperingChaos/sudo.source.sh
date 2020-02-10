#!/bin/bash
main(){
	local -r projRoot="$1"

	local -r repo='https://github.com/WhisperingChaos/config.sh' 
	local -r ver='master' 
	local -r repoVerUrl="$repo"'/tarball/'"$ver"
	local -r configDir='./config' 
	if ! [ -d "$configDir" ]; then 
		mkdir $configDir
	fi
	wget --dns-timeout=5 --connect-timeout=10 --read-timeout=60 -O -  "$repoVerUrl" 2>/dev/null \
	| tar -xz -C $configDir --strip-component=2 --wildcards --no-wildcards-match-slash --anchor '*/component/'
	if ! [[ "${PIPESTATUS[0]}" && "${PIPESTATUS[1]}" ]]; then
		echo "error: msg='failed download/install' repoVerUrl='$repoVerUrl'"
		exit 1
	fi
	$configDir/config.sh "$projRoot" 
}
set -e
main "$( dirname "${BASH_SOURCE[0]}" )"

