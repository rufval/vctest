#
# Copyright © 2019 Dmitry Yudin. All rights reserved.
# Licensed under the Apache License, Version 2.0
#
set -eu -o pipefail

dirScript=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
. "$dirScript/utility_functions.sh"
. "$dirScript/codec.sh"
. "$dirScript/remote_target.sh"

PRMS="28 34 39 44"
REPORT=report.log
REPORT_KW=
CODECS="ashevc x265 kvazaar kingsoft ks intel_sw intel_hw h265demo h265demo_v2 h264demo "\
"h264aspt vp8 vp9"
PRESETS=
THREADS=1
VECTORS="
	akiyo_352x288_30fps.yuv
	foreman_352x288_30fps.yuv
"
DIR_OUT=$(ospath "$dirScript"/../out)
DIR_VEC=$(ospath "$dirScript"/../vectors)
NCPU=0
readonly ffmpegExe=$dirScript/../'bin/ffmpeg.exe'
readonly ffprobeExe=$dirScript/../'bin/ffprobe.exe'
readonly timestamp=$(date "+%Y.%m.%d-%H.%M.%S")
readonly dirTmp=$(tempdir)/vctest/$timestamp

usage()
{
	cat	<<-EOF
	Usage:
	    $(basename $0) [opt]

	Options:
	    -h|--help        Print help.
	    -i|--input   <x> Input YUV files relative to '/vectors' directory. Multiple '-i vec' allowed.
	                     '/vectors' <=> '$(ospath "$dirScript/../vectors")'
	    -o|--output  <x> Report path. Default: "$REPORT".
	    -c|--codec   <x> Codecs list. Default: "$CODECS".
	    -t|--threads <x> Number of threads to use
	    -p|--prms    <x> Bitrate (kbps) or QP list. Default: "$PRMS".
	                     Values less than 60 considered as QP.
	       --preset  <x> Codec-specific list of 'preset' options (default: marked by *):
	                       ashevc:   *1 2 3 4 5 6
	                       x265:     *ultrafast  superfast veryfast  faster fast medium slow slower veryslow placebo
	                       kvazaar:  *ultrafast  superfast veryfast  faster fast medium slow slower veryslow placebo
	                       kingsoft:  ultrafast *superfast veryfast         fast medium slow        veryslow placebo
	                       ks:        ultrafast *superfast veryfast         fast medium slow        veryslow placebo
	                       intel_sw:                       veryfast *faster fast medium slow slower veryslow
	                       intel_hw:                       veryfast  faster fast medium slow slower veryslow
	                       h265demo: 6 *5 4 3 2 1
	                       h265demo_v2: 6 *5   3 2
	                       h264demo: N/A
	                       h264aspt: 0 (slow) - 10 (fast)
	                       vp8: 0 (slow) - 16 (fast)
	                       vp9: 0 (slow) -  9 (fast)
	    -j|--ncpu    <x> Number of encoders to run in parallel. The value of '0' will run as many encoders as many
	                     CPUs available. Default: $NCPU
	                     Note, execution time based profiling data (CPU consumption and FPS estimation) is not
	                     available in parallel execution mode.
	       --hide        Do not print legend and header.
	       --adb         Run Android@ARM using ADB. | Credentials are read from 'remote.local' file.
	       --ssh         Run Linux@ARM using SSH.   |         (see example for details)
	       --force       Invalidate results cache
	EOF
}

entrypoint()
{
	local cmd_vec= cmd_report= cmd_codecs= cmd_threads= cmd_prms= cmd_presets= cmd_ncpu= cmd_endofflags=
	local hide_banner= target= force=
	local remote=false targetInfo=
	while [[ "$#" -gt 0 ]]; do
		local nargs=2
		case $1 in
			-h|--help)		usage && return;;
			-i|--in*) 		cmd_vec="$cmd_vec $2";;
			-o|--out*) 		cmd_report=$2;;
			-c|--codec*) 	cmd_codecs=$2;;
			-t|--thread*)   cmd_threads=$2;;
			-p|--prm*) 		cmd_prms=$2;;
			   --pre*) 		cmd_presets=$2;;
			-j|--ncpu)		cmd_ncpu=$2;;
			   --hide)		hide_banner=1; nargs=1;;
			   --adb)       target=adb; remote=true; nargs=1;;
			   --ssh)       target=ssh; remote=true; nargs=1;;
               --force)     force=1; nargs=1;;
			   --)			cmd_endofflags=1; nargs=1;;
			*) error_exit "unrecognized option '$1'"
		esac
		shift $nargs
		[[ -n "$cmd_endofflags" ]] && break
	done
	[[ -n "$cmd_report" ]] && REPORT=${cmd_report//\\//}
	[[ -n "$cmd_vec" ]] && VECTORS=${cmd_vec# }
	[[ -n "$cmd_codecs" ]] && CODECS=$cmd_codecs
	[[ -n "$cmd_threads" ]] && THREADS=$cmd_threads
	[[ -n "$cmd_prms" ]] && PRMS=$cmd_prms
	[[ -n "$cmd_presets" ]] && PRESETS=$cmd_presets
	[[ -n "$cmd_ncpu" ]] && NCPU=$cmd_ncpu

    # Currently only used by bd-rate script
    REPORT_KW=$DIR_OUT/${REPORT##*/}.kw

	target=${target:-windows}
	PRESETS=${PRESETS:--}
	# for multithreaded run, run in single process to get valid cpu usage estimation
	[[ $THREADS -gt 1 ]] && NCPU=1

	if $remote; then
		TARGET_setTarget $target "$dirScript"/../remote.local
		TARGET_getFingerprint; targetInfo=$REPLY
	fi
	if [[ -n "$cmd_endofflags" ]]; then
		echo "exe: $@"
		"$@"
		return $?
	fi

	mkdir -p "$DIR_OUT" "$(dirname $REPORT)"

	# Remove non-existing and set abs-path
	vectors_verify $remote $VECTORS; VECTORS=$REPLY

	# Remove codecs we can't run
	codec_verify $remote $target $CODECS; CODECS=$REPLY

	local startSec=$SECONDS

    mkdir -p "$dirTmp"

	#
	# Scheduling
	#
	progress_begin "[1/5] Scheduling..." "$PRMS" "$VECTORS" "$CODECS" "$PRESETS"

	local optionsFile="$dirTmp"/options.txt
	prepare_optionsFile $target "$optionsFile"

	local encodeList= decodeList= parseList= reportList=
	while read info; do
		local encExeHash encCmdHash
		dict_getValue "$info" encExeHash; encExeHash=$REPLY
		dict_getValue "$info" encCmdHash; encCmdHash=$REPLY
		local outputDirRel="$encExeHash/$encCmdHash"
		local outputDir="$DIR_OUT/$outputDirRel"

		local encode=false
		if [[ -n "$force" || ! -f "$outputDir/encoded.ts" ]]; then
			encode=true
		elif [[ $NCPU -eq 1 && ! -f "$outputDir/cpu.log" ]]; then
			# cpu load monitoring is currently disabled for a remote run
			! $remote && encode=true  # update CPU log
		fi
		if $encode; then
			# clean up target directory if we need to start from a scratch
			rm -rf "$outputDir"		# this alos force decoding and parsing
			mkdir -p "$outputDir"

			# readonly kw-file will be used across all processing stages
			echo "$info" > $outputDir/info.kw

			encodeList="$encodeList $outputDirRel"
		fi
		if [[ ! -f "$outputDir/decoded.ts" ]]; then
			decodeList="$decodeList $outputDirRel"
		fi
		if [[ ! -f "$outputDir/parsed.ts" ]]; then
			parseList="$parseList $outputDirRel"
		fi
		reportList="$reportList $outputDirRel"

		progress_next "$outputDirRel"

	done < $optionsFile
	rm -f "$optionsFile"
	progress_end

	local self
	relative_path "$0"; self=$REPLY # just to make output look nicely

	local testplan=$dirTmp/testplan.txt

	#
	# Encoding
	#
	progress_begin "[2/5] Encoding..." "$encodeList"
	if [[ -n "$encodeList" ]]; then
		for outputDirRel in $encodeList; do
			echo "$self --ncpu $NCPU -- encode_single_file $remote \"$outputDirRel\""
		done > $testplan
		execute_plan $testplan $NCPU
	fi
	progress_end

	#
	# Decoding
	#
	NCPU=-2 # use (all+1) cores for decoding
	progress_begin "[3/5] Decoding..." "$decodeList"
	if [[ -n "$decodeList" ]]; then
		for outputDirRel in $decodeList; do
			echo "$self -- decode_single_file \"$outputDirRel\""
		done > $testplan
		execute_plan $testplan $NCPU
	fi
	progress_end

	#
	# Parsing
	#
	NCPU=-3 # use (all + 2) cores
	progress_begin "[4/5] Parsing..." "$parseList"
	if [[ -n "$parseList" ]]; then
		for outputDirRel in $parseList; do
			echo "$self -- parse_single_file \"$outputDirRel\""
		done > $testplan
		execute_plan $testplan $NCPU
	fi
	progress_end

	rm -f -- $testplan

	#
	# Reporting
	#
	local info=$target
	$remote && info="$info [remote]" || info="$info [local]"
	[[ -n "$targetInfo" ]] && info="$info [$targetInfo]"
	progress_begin "[5/5] Reporting..."	"$reportList"
	if [[ -z "$hide_banner" ]]; then
		echo "$timestamp $info" >> $REPORT
		echo "$timestamp $info" >> $REPORT_KW

		output_legend
		output_header
	fi
	for outputDirRel in $reportList; do
		progress_next "$outputDirRel"
		report_single_file "$outputDirRel"
	done
	progress_end

	local duration=$(( SECONDS - startSec ))
	duration=$(date +%H:%M:%S -u -d @${duration})
	print_console "$duration >>>> $REPORT $info\n"
}

vectors_verify()
{
	local remote=$1; shift
	local VECTORS="$*"

	local VECTORS_REL= vec=
	for vec in $VECTORS; do
		if [[ -f "$DIR_VEC/$vec" ]]; then
            relative_path "$DIR_VEC/$vec" "$DIR_VEC"; vec=$REPLY # normalize name if any
			VECTORS_REL="$VECTORS_REL $vec"
		else
			echo "warning: can't find vector in '$DIR_VEC'. Remove '$vec' from a list." >&2
		fi
	done
	VECTORS=${VECTORS_REL# }

	if $remote; then
		local remoteDirVec= targetDirPrev=
		TARGET_getDataDir; remoteDirVec=$REPLY/vctest/vectors
		print_console "Push vectors to remote machine $remoteDirVec ...\n"
		for vec in $VECTORS_REL; do
            print_console "$vec\r"
            local targetDir=$remoteDirVec/${vec%/*}
            if [[ "$targetDirPrev" != "$targetDir" ]]; then
        		TARGET_exec "mkdir -p $targetDir"
                targetDirPrev=$targetDir
            fi
			TARGET_pushFileOnce "$DIR_VEC/$vec" "$remoteDirVec/$vec"
		done
	fi
	REPLY=$VECTORS
}

prepare_optionsFile()
{
	local target=$1; shift
	local optionsFile=$1; shift

	local prm= src= codecId= preset= infoTmpFile=$(mktemp)
	for prm in $PRMS; do
	for src in $VECTORS; do
	for codecId in $CODECS; do
	for preset in $PRESETS; do
		local qp=- bitrate=-
		if [[ $prm -lt 60 ]]; then
			qp=$prm
		else
			bitrate=$prm
		fi
		[[ $preset == '-' ]] && { codec_default_preset "$codecId"; preset=$REPLY; }
		local srcRes= srcFps= srcNumFr=
		detect_resolution_string "$DIR_VEC/$src"; srcRes=$REPLY
		detect_framerate_string "$DIR_VEC/$src"; srcFps=$REPLY
		detect_frame_num "$DIR_VEC/$src" "$srcRes"; srcNumFr=$REPLY

		local args="--res "$srcRes" --fps $srcFps --threads $THREADS"
		[[ $bitrate == '-' ]] || args="$args --bitrate $bitrate"
		[[ $qp == '-' ]]     || args="$args --qp $qp"
		[[ $preset == '-' ]] || args="$args --preset $preset"

		local encExe= encExeHash= encCmdArgs= encCmdHash=
		codec_exe $codecId $target; encExe=$REPLY
		codec_hash $codecId $target; encExeHash=$REPLY
		codec_cmdArgs $codecId $args; encCmdArgs=$REPLY

		local SRC=${src//\\/}; SRC=${SRC##*[/\\]} # basename only
		local ext=h265; [[ $codecId == h264demo ]] && ext=h264
		local dst="$SRC.$ext"

		local info="src:$src codecId:$codecId srcRes:$srcRes srcFps:$srcFps srcNumFr:$srcNumFr"
		info="$info QP:$qp BR:$bitrate PRESET:$preset TH:$THREADS SRC:$SRC dst:$dst"
		info="$info encExe:$encExe encExeHash:$encExeHash encCmdArgs:$encCmdArgs"
		printf '%s\n' "$info"
	done
	done
	done
	done > $infoTmpFile

	local hashTmpFile=$(mktemp)
	while read data; do
		local encCmdArgs src
		dict_getValueEOL "$data" encCmdArgs; encCmdArgs=$REPLY
		dict_getValue "$data" src; src=$REPLY
		local args=${encCmdArgs// /}   # remove all whitespaces
		echo "$src $args"
	done < $infoTmpFile | python "$(ospath "$dirScript")/md5sum.py" | tr -d $'\r' > $hashTmpFile

	local data encCmdHash
	while IFS= read -u3 -r encCmdHash && IFS= read -u4 -r data; do 
  		printf 'encCmdHash:%s %s\n' "$encCmdHash" "$data"
	done 3<$hashTmpFile 4<$infoTmpFile > $optionsFile
	rm $infoTmpFile $hashTmpFile
}

execute_plan()
{
	local testplan=$1; shift
	local ncpu=$1; shift
	"$dirScript/rpte2.sh" $testplan -p $dirTmp -j $ncpu
}

PERF_ID=
start_cpu_monitor()
{
	local codecId=$1; shift
	local cpuLog=$1; shift

	local encExe=
	codec_exe $codecId windows; encExe=$REPLY

	local name=${encExe##*/}; name=${name%.*}

	local cpu_monitor_type=posix; case ${OS:-} in *_NT) cpu_monitor_type=windows; esac
	if [[ $cpu_monitor_type == windows ]]; then
		typeperf '\Process('$name')\% Processor Time' &
		PERF_ID=$!
	else
		# TODO: posix compatible monitor
		:
	fi
}
stop_cpu_monitor()
{
	[[ -z "$PERF_ID" ]] && return 0
	{ kill -s INT $PERF_ID && wait $PERF_ID; } || true 
	PERF_ID=
}

PROGRESS_SEC=
PROGRESS_HDR=
PROGRESS_INFO=
PROGRESS_CNT_TOT=0
PROGRESS_CNT=0
progress_begin()
{
	local name=$1; shift
	local str=
	PROGRESS_SEC=$SECONDS
	PROGRESS_HDR=
	PROGRESS_INFO=
	PROGRESS_CNT_TOT=1
	PROGRESS_CNT=0

	for str; do
		list_size "$1"; PROGRESS_CNT_TOT=$(( PROGRESS_CNT_TOT * REPLY))
		shift
	done
	print_console "$name\n"

	if [[ $PROGRESS_CNT_TOT == 0 ]]; then
		print_console "No tasks to execute\n\n"
	else
		printf 	-v str "%8s %4s %-11s %11s %5s %2s %6s" "Time" $PROGRESS_CNT_TOT codecId resolution '#frm' QP BR 
		printf 	-v str "%s %9s %2s %-16s %-8s %s" "$str" PRESET TH CMD-HASH ENC-HASH SRC
		PROGRESS_HDR=$str
	fi
}
progress_next()
{
	local outputDirRel=$1; shift
	local outputDir="$DIR_OUT/$outputDirRel" info=

    { read -r info; } < "$outputDir/info.kw"

	if [[ -n "$PROGRESS_HDR" ]]; then
		print_console "$PROGRESS_HDR\n"
		PROGRESS_HDR=
	fi

	PROGRESS_CNT=$(( PROGRESS_CNT + 1 ))

	local codecId= srcRes= srcFps= srcNumFr= QP= BR= PRESET= TH= SRC= HASH= ENC=
	dict_getValue "$info" codecId  ; codecId=$REPLY
	dict_getValue "$info" srcRes   ; srcRes=$REPLY
	dict_getValue "$info" srcFps   ; srcFps=$REPLY
	dict_getValue "$info" srcNumFr ; srcNumFr=$REPLY
	dict_getValue "$info" QP       ; QP=$REPLY
	dict_getValue "$info" BR       ; BR=$REPLY
	dict_getValue "$info" PRESET   ; PRESET=$REPLY
	dict_getValue "$info" TH       ; TH=$REPLY
	dict_getValue "$info" SRC      ; SRC=$REPLY
	dict_getValue "$info" encCmdHash ; HASH=$REPLY ; HASH=${HASH::16}
	dict_getValue "$info" encExeHash ; ENC=$REPLY  ; ENC=${ENC##*_}

	local str=
	printf 	-v str "%4s %-11s %11s %5s %2s %6s" 	"$PROGRESS_CNT" "$codecId" "${srcRes}@${srcFps}" "$srcNumFr" "$QP" "$BR"
	printf 	-v str "%s %9s %2s %-16s %-8s %s"    "$str" "$PRESET" "$TH" "$HASH" "$ENC" "$SRC"
	PROGRESS_INFO=$str # backup

	local duration=$(( SECONDS - PROGRESS_SEC ))
	duration=$(date +%H:%M:%S -u -d @${duration})

	print_console "$duration $PROGRESS_INFO\r"
}
progress_end()
{
	[[ $PROGRESS_CNT == 0 ]] && return

	local duration=$(( SECONDS - PROGRESS_SEC ))
	duration=$(date +%H:%M:%S -u -d @${duration})

	print_console "$duration $PROGRESS_INFO\n"

	PROGRESS_CNT_TOT=0
}

output_header()
{
	local str=
	printf 	-v str    "%6s %8s %5s %5s"                extFPS intFPS cpu% kbps
	printf 	-v str "%s %3s %7s %6s %4s"         "$str" '#I' avg-I avg-P peak 
	printf 	-v str "%s %6s %6s %6s %6s"         "$str" gPSNR psnr-I psnr-P gSSIM
	printf 	-v str "%s %-11s %11s %5s %2s %6s"	"$str" codecId resolution '#frm' QP BR 
	printf 	-v str "%s %9s %2s %-16s %-8s %s" 	"$str" PRESET TH CMD-HASH ENC-HASH SRC

#	print_console "$str\n"

	echo "$str" >> "$REPORT"
}
output_legend()
{
	local str=$(cat <<-'EOT'
		extFPS     - Estimated FPS: numFrames/encoding_time_sec		
		intFPS     - FPS counter reported by codec
		cpu%       - CPU load (100% <=> 1 core). Might be zero if encoding takes less than 1 sec
		kbps       - Actual bitrate: filesize/content_len_sec
		#I         - Number of INTRA frames
		avg-I      - Average INTRA frame size in bytes
		avg-P      - Average P-frame size in bytes
		peak       - Peak factor: avg-I/avg-P
		gPSNR      - Global PSNR. Follows x265 notation: (6*avgPsnrY + avgPsnrU + avgPsnrV)/8
		psnr-I     - Global PSNR. I-frames only
		psnr-P     - Global PSNR. P-frames only
		gSSIM      - Global SSIM in dB: -10*log10(1-ssim)
		QP         - QP value for fixed QP mode
		BR         - Target bitrate.
		TH         - Threads number.
	EOT
	)

#	echo "$str" > /dev/tty
}
output_report()
{
	local dict="$*"

	echo "$dict" >> $REPORT_KW

	local extFPS= intFPS= cpu= kbps= numI= avgI= avgP= peak= gPSNR= psnrI= psnrP= gSSIM=
	local codecId= srcRes= srcFps= numFr= QP= BR= PRESET= TH= SRC= HASH= ENC=

	dict_getValue "$dict" extFPS  ; extFPS=$REPLY
	dict_getValue "$dict" intFPS  ; intFPS=$REPLY
	dict_getValue "$dict" cpu     ; cpu=$REPLY
	dict_getValue "$dict" kbps    ; kbps=$REPLY
	dict_getValue "$dict" numI    ; numI=$REPLY
	dict_getValue "$dict" avgI    ; avgI=$REPLY
	dict_getValue "$dict" avgP    ; avgP=$REPLY
	dict_getValue "$dict" peak    ; peak=$REPLY
	dict_getValue "$dict" gPSNR   ; gPSNR=$REPLY
	dict_getValue "$dict" psnrI   ; psnrI=$REPLY
	dict_getValue "$dict" psnrP   ; psnrP=$REPLY
	dict_getValue "$dict" gSSIM   ; gSSIM=$REPLY
	dict_getValue "$dict" codecId ; codecId=$REPLY
	dict_getValue "$dict" srcRes  ; srcRes=$REPLY
	dict_getValue "$dict" srcFps  ; srcFps=$REPLY
	dict_getValue "$dict" srcNumFr; srcNumFr=$REPLY
	dict_getValue "$dict" QP      ; QP=$REPLY
	dict_getValue "$dict" BR      ; BR=$REPLY
	dict_getValue "$dict" PRESET  ; PRESET=$REPLY
	dict_getValue "$dict" TH      ; TH=$REPLY
	dict_getValue "$dict" SRC     ; SRC=$REPLY
	dict_getValue "$dict" encCmdHash; HASH=$REPLY; HASH=${HASH::16}
	dict_getValue "$dict" encExeHash; ENC=$REPLY ; ENC=${ENC##*_}

	local str=
	printf 	-v str    "%6s %8.3f %5s %5.0f"            "$extFPS" "$intFPS" "$cpu" "$kbps"
	printf 	-v str "%s %3d %7.0f %6.0f %4.1f"   "$str" "$numI" "$avgI" "$avgP" "$peak"
	printf 	-v str "%s %6.2f %6.2f %6.2f %6.3f" "$str" "$gPSNR" "$psnrI" "$psnrP" "$gSSIM"
	printf 	-v str "%s %-11s %11s %5d %2s %6s"	"$str" "$codecId" "${srcRes}@${srcFps}" "$srcNumFr" "$QP" "$BR"
	printf 	-v str "%s %9s %2s %-16s %-8s %s" 	"$str" "$PRESET" "$TH" "$HASH" "$ENC" "$SRC"

#	print_console "$str\n"
	echo "$str" >> $REPORT
}

report_single_file()
{
	local outputDirRel=$1; shift
	local outputDir="$DIR_OUT/$outputDirRel"

	local info= report=
    { read -r info; } < "$outputDir/info.kw"
    { read -r report; } < "$outputDir/report.kw"

	output_report "$info $report"
}

encode_single_file()
{
	local remote=$1; shift
	local outputDirRel=$1; shift
	local outputDir="$DIR_OUT/$outputDirRel"
	pushd "$outputDir"

	local info= encCmdArgs= codecId= src= dst= encCmdSrc= encCmdDst= srcNumFr=
    { read -r info; } < "info.kw"

	dict_getValueEOL "$info" encCmdArgs; encCmdArgs=$REPLY
	dict_getValue "$info" codecId; codecId=$REPLY
	dict_getValue "$info" encExe; encExe=$REPLY
	dict_getValue "$info" src; src=$REPLY
	dict_getValue "$info" dst; dst=$REPLY
	dict_getValue "$info" srcNumFr; srcNumFr=$REPLY

	if ! $remote; then
        encExe=$DIR_BIN/$encExe
        src=$DIR_VEC/$src
    else
		local remoteDirBin= remoteDirVec=
		TARGET_getExecDir; remoteDirBin=$REPLY/vctest/bin
		TARGET_getDataDir; remoteDirVec=$REPLY/vctest/vectors
		encExe=$remoteDirBin/$encExe
		src=$remoteDirVec/$src
	fi
	codec_cmdSrc $codecId "$src"; encCmdSrc=$REPLY
	codec_cmdDst $codecId "$dst"; encCmdDst=$REPLY

	# temporary hack, for backward compatibility (remove later)
	[[ $codecId == h265demo ]] && encCmdArgs="-c h265demo.cfg $encCmdArgs"

	local cmd="$encExe $encCmdArgs $encCmdSrc $encCmdDst"
	echo "$cmd" > cmd # memorize

	local stdoutLog=stdout.log
	local cpuLog=cpu.log
	local fpsLog=fps.log

	if ! $remote; then
		# temporary hack, for backward compatibility (remove later)
		[[ $codecId == h265demo ]] && echo "" > h265demo.cfg

		# Make estimates only if one instance of the encoder is running at a time
		local estimate_execution_time=false
		if [[ $NCPU == 1 ]]; then
			estimate_execution_time=true
		fi

		if $estimate_execution_time; then
			# Start CPU monitor
			trap 'stop_cpu_monitor 1>/dev/null 2>&1' EXIT
			start_cpu_monitor "$codecId" "$cpuLog" > $cpuLog
		fi

		# Encode
		local consumedNsec=$(date +%s%3N) # seconds*1000
		if ! { echo "yes" | $cmd; } 1>$stdoutLog 2>&1 || [ ! -f "$dst" ]; then
			echo "" # newline if stderr==tty
			cat "$stdoutLog" >&2
			error_exit "encoding error, see logs above"
		fi
		consumedNsec=$(( $(date +%s%3N) - consumedNsec ))

		if $estimate_execution_time; then
			local fps=0
			[[ $consumedNsec != 0 ]] && fps=$(( 1000*srcNumFr/consumedNsec ))
			echo "$fps" > $fpsLog

			# Stop CPU monitor
			stop_cpu_monitor
			trap -- EXIT
		fi
	else
		local remoteDirOut remoteOutputDir
		TARGET_getDataDir; remoteDirOut=$REPLY/vctest/out
		remoteOutputDir=$remoteDirOut/$outputDirRel

		TARGET_exec "
			rm -rf $remoteOutputDir && mkdir -p $remoteOutputDir && cd $remoteOutputDir

			# temporary hack, for backward compatibility (remove later)
			[ $codecId == h265demo ] && echo \"\" > h265demo.cfg
#
# Disabled for a while to run encoder in foreground
#
#			start_cpu_monitor() {
#				local worker_pid=\$1; shift
#				{ while ps -o '%cpu=,cpu=' -p \$worker_pid >> $cpuLog; do sleep .5s; done; } &
#				PERF_ID=\$!
#			}
#			stop_cpu_monitor() {
#				echo \"waiting CPU monitor with pid=\$PERF_ID to stop\"
#				kill \$PERF_ID && wait \$PERF_ID || true
#				echo \"CPU monitor stopped\"
#			}
#			consumedSec=\$(date +%s)
#			$cmd </dev/null 1>$stdoutLog 2>&1 &
#			pid=\$!
#			start_cpu_monitor \$pid
#			error_code=0
#			wait \$pid || error_code=\$?
#  			consumedSec=\$(( \$(date +%s) - consumedSec ))
#			stop_cpu_monitor

			consumedSec=\$(date +%s)
			$cmd </dev/null 1>$stdoutLog 2>&1
			error_code=0
  			consumedSec=\$(( \$(date +%s) - consumedSec ))

			[ \$consumedSec != 0 ] && fps=\$(( $srcNumFr/consumedSec ))
			if [ \$error_code != 0 -o ! -f $dst ]; then
				echo "" # newline if stderr==tty
				cat $stdoutLog >&2
				return 1
			fi
			echo "\$fps" > $fpsLog
		"
		TARGET_pull $remoteOutputDir/. .
		TARGET_exec "rm -rf $remoteOutputDir"
	fi
	date "+%Y.%m.%d-%H.%M.%S" > encoded.ts

	popd
}

decode_single_file()
{
	local outputDirRel=$1; shift
	local outputDir="$DIR_OUT/$outputDirRel"
	pushd "$outputDir"

	local info= src= dst=
    { read -r info; } < "info.kw"

	dict_getValue "$info" src; src=$REPLY
	dict_getValue "$info" dst; dst=$REPLY

	local recon=$(basename "$dst").yuv
	local kbpsLog=kbps.log
	local infoLog=info.log
	local ssimLog=ssim.log
	local psnrLog=psnr.log
	local frameLog=frame.log
	local summaryLog=summary.log

	local srcRes= srcFps= srcNumFr=
	dict_getValue "$info" srcRes; srcRes=$REPLY
	dict_getValue "$info" srcFps; srcFps=$REPLY
	dict_getValue "$info" srcNumFr; srcNumFr=$REPLY

	$ffmpegExe -y -loglevel error -i "$dst" "$recon"
	$ffprobeExe -v error -show_frames -i "$dst" | tr -d $'\r' > $infoLog

	local sizeInBytes= kbps=
	sizeInBytes=$(stat -c %s "$dst")
	kbps=$(awk "BEGIN { print 8 * $sizeInBytes / ($srcNumFr/$srcFps) / 1000 }")
	echo "$kbps" > $kbpsLog

	# ffmpeg does not accept filename in C:/... format as a filter option
	if ! log=$($ffmpegExe -hide_banner -s $srcRes -i "$DIR_VEC/$src" -s $srcRes -i "$recon" -lavfi "ssim=$ssimLog;[0:v][1:v]psnr=$psnrLog" -f null - ); then
		echo "$log" && return 1
	fi
	rm -f "$recon"

	local numI=0 numP=0 sizeI=0 sizeP=0
	{
		local type= size= cnt=0
		while read -r; do
			case $REPLY in
				'[FRAME]')
					type=
					size=
					cnt=$(( cnt + 1 ))
				;;
				'[/FRAME]')
					[[ $type == I ]] && numI=$(( numI + 1 )) && sizeI=$(( sizeI + size ))
					[[ $type == P ]] && numP=$(( numP + 1 )) && sizeP=$(( sizeP + size ))
					echo "n:$cnt type:$type size:$size"
				;;
			esac
			case $REPLY in
				pict_type=I) type=I;;
				pict_type=P) type=P;;
			esac
			case $REPLY in pkt_size=*) size=${REPLY#pkt_size=}; esac
			# echo $v
		done < $infoLog
	} > $frameLog

	paste "$frameLog" "$psnrLog" "$ssimLog" | tr -d $'\r' > $summaryLog

	date "+%Y.%m.%d-%H.%M.%S" > decoded.ts

	popd
}

parse_single_file()
{
	local outputDirRel=$1; shift
	local outputDir="$DIR_OUT/$outputDirRel"
	pushd "$outputDir"

	local info= codecId=
    { read -r info; } < "info.kw"

	dict_getValue "$info" codecId; codecId=$REPLY

	local stdoutLog=stdout.log
	local kbpsLog=kbps.log
	local cpuLog=cpu.log
	local fpsLog=fps.log
	local summaryLog=summary.log

	local cpuAvg=- extFPS=- intFPS= framestat=
	if [[ -f "$cpuLog" ]]; then # may not exist
		cpuAvg=$(parse_cpuLog "$cpuLog")
		printf -v cpuAvg "%.0f" "$cpuAvg"
	fi
	if [[ -f "$fpsLog" ]]; then # may not exist
        { read -r extFPS; } < "$fpsLog"
	fi
	intFPS=$(parse_stdoutLog "$codecId" "$stdoutLog")
	framestat=$(parse_framestat "$kbpsLog" "$summaryLog")

	local dict="extFPS:$extFPS intFPS:$intFPS cpu:$cpuAvg $framestat"
	echo "$dict" > report.kw

	date "+%Y.%m.%d-%H.%M.%S" > parsed.ts

	popd
}

parse_framestat()
{
	local kbpsLog=$1; shift
	local summaryLog=$1; shift

	local kbps= summary=
    { read -r kbps; } < "$kbpsLog"

    local script='
        function get_value(name,           a, b) {
            split ($0, a, name);
            split (a[2], b);
            return b[1];
        }
    	function countGlobalPSNR(psnr_y, psnr_u, psnr_v) {
            return ( 6*psnr_y + psnr_u + psnr_v ) / 8;
	    }
	    function x265_ssim2dB(ssim) {
			return (1 - ssim) <= 0.0000000001 ? 100 : -10*log(1 - ssim)/log(10)
	    }

        BEGIN {
        } 
           
        {
            psnr_y = get_value("psnr_y:");
            psnr_u = get_value("psnr_u:");
            psnr_v = get_value("psnr_v:");
            ssim = get_value("Y:");
            size = get_value("size:");
        }
        {
                   num++;  psnr_y_avg  += psnr_y; psnr_u_avg  += psnr_u; psnr_v_avg  += psnr_v; ssim_avg  += ssim;
        }

        /type:I/ { numI++; psnr_y_avgI += psnr_y; psnr_u_avgI += psnr_u; psnr_v_avgI += psnr_v; ssim_avgI += ssim; sizeI += size; }
        /type:P/ { numP++; psnr_y_avgP += psnr_y; psnr_u_avgP += psnr_u; psnr_v_avgP += psnr_v; ssim_avgP += ssim; sizeP += size; }
        END {
            if( num > 0 ) {
                psnr_y_avg  /= num;  psnr_u_avg  /= num;  psnr_v_avg  /= num;  ssim_avg  /= num;
            }

            if( numI > 0 ) {
                psnr_y_avgI /= numI; psnr_u_avgI /= numI; psnr_v_avgI /= numI; ssim_avgI /= numI; avgI = sizeI/numI;
            }
            if( numP > 0 ) {
                psnr_y_avgP /= numP; psnr_u_avgP /= numP; psnr_v_avgP /= numP; ssim_avgP /= numP; avgP = sizeP/numP;
            }

            gPSNR = countGlobalPSNR(psnr_y_avg,  psnr_u_avg,  psnr_v_avg );  gSSIM = ssim_avg
            psnrI = countGlobalPSNR(psnr_y_avgI, psnr_u_avgI, psnr_v_avgI);  ssimI = ssim_avgI
            psnrP = countGlobalPSNR(psnr_y_avgP, psnr_u_avgP, psnr_v_avgP);  ssimP = ssim_avgP
            peak = avgP > 0 ? avgI/avgP : 0;

            gSSIM_db=x265_ssim2dB(gSSIM)
            print "numI:"numI" numP:"numP" sizeI:"sizeI" sizeP:"sizeP\
                 " avgI:"avgI" avgP:"avgP" peak:"peak\
                 " psnrI:"psnrI" psnrP:"psnrP" gPSNR:"gPSNR\
                 " ssimI:"ssimI" ssimP:"ssimP" gSSIM:"gSSIM_db\
                 " gSSIM_db:"gSSIM_db" gSSIM_en:"gSSIM
        }
    '
    summary=$(awk "$script" "$summaryLog")

    echo "kbps:$kbps $summary"
}

parse_cpuLog()
{
	local log=$1; shift
	local cpu_monitor_type=posix; case ${OS:-} in *_NT) cpu_monitor_type=windows; esac

	if [[ $cpu_monitor_type == windows ]]; then
#: <<'FORMAT'
#                                                                             < skip (first line is empty)
#"(PDH-CSV 4.0)","\\DESKTOP-7TTKF98\Process(sample_encode)\% Processor Time"  < skip
#"04/02/2020 07:37:58.154","388.873717"                                       < count average
#"04/02/2020 07:37:59.205","390.385101"
#FORMAT
		cat "$log" | tail -n +3 | cut -d, -f 2 | tr -d \" | 
				awk '{ if ( $1 != "" && $1 > 0 ) { sum += $1; cnt++; } } END { print cnt !=0 ? sum / cnt : 0 }'
	else
		 # expect '%cpu' is a first column delimited by ' '
		cat "$log" | cut -d' ' -f 1 | tr -d \" | 
				awk '{ if ( $1 != "" && $1 > 0 ) { sum += $1; cnt++; } } END { print cnt !=0 ? sum / cnt : 0 }'
	fi
}

parse_stdoutLog()
{
	local codecId=$1; shift
	local log=$1; shift
	local fps= snr=
	case $codecId in
		ashevc)
			fps=$(grep -i ' fps)'           "$log" | tr -s ' ' | cut -d' ' -f 6); fps=${fps#(}
		;;
		x265)
			fps=$(grep -i ' fps)'           "$log" | tr -s ' ' | cut -d' ' -f 6); fps=${fps#(}
		;;
		kvazaar)
			fps=$(grep -i ' FPS:'           "$log" | tr -s ' ' | cut -d' ' -f 3)
		;;
		kingsoft)
			fps=$(grep -i 'test time: '     "$log" | tr -s ' ' | cut -d' ' -f 8)
			#fps=$(grep -i 'pure encoding time:' "$log" | head -n 1 | tr -s ' ' | cut -d' ' -f 8)
		;;
		ks)
			fps=$(grep -i 'FPS: '           "$log" | tr -s ' ' | cut -d' ' -f 2)
		;;
		intel_*)
			fps=$(grep -i 'Encoding fps:'   "$log" | tr -s ' ' | cut -d' ' -f 3)
		;;
		h265demo)
			fps=$(grep -i 'TotalFps:'       "$log" | tr -s ' ' | cut -d' ' -f 5)
		;;
		h265demo_v2)
			fps=$(grep -i 'Encode speed:'   "$log" | tr -s ' ' | cut -d' ' -f 9)
			fps=${fps%%fps}
        ;;
		h265demo_v3)
            fps=$(grep -i 'Encode pure speed:'   "$log" | tr -s ' ' | cut -d' ' -f 4)
#			fps=$(grep -i 'Encode speed:'   "$log" | tr -s ' ' | cut -d' ' -f 9)
			fps=${fps%%fps*}
		;;
		h264demo)
			fps=$(grep -i 'Tests completed' "$log" | tr -s ' ' | cut -d' ' -f 1)
		;;
		h264aspt)
			fps=$(grep -i 'fps$' "$log" | tr -s ' ' | cut -d' ' -f 3)
		;;
		vp8|vp9) # be carefull with multipass
            fps=$(cat "$log" | tr "\r" "\n" | grep -E '\([0-9]{1,}\.[0-9]{1,} fps\)' | tail -n 1 | tr -d '()' | tr -s ' ' | cut -d' ' -f 10)
		;;

		*) error_exit "unknown encoder: $codecId";;
	esac

	echo "$fps"
}

entrypoint "$@"

# https://filmora.wondershare.com/video-editing-tips/what-is-video-bitrate.html
# Quality   ResolutionVideo   Bitrate  [ Open Broadcasting Software ]
# LOW        480x270           400
# Medium     640x360           800-1200
# High       960x540/854x480  1200-1500
# HD        1280x720          1500-4000
# HD1080    1920x1080	      4000-8000
# 4K        3840x2160         8000-14000

# https://bitmovin.com/video-bitrate-streaming-hls-dash/  H.264
# Resolution	FPS	Bitrate   Bits/Pixel
#  426x240       24      250   400   700 0.10 0.17 0.29
#  640x360       24      500   800  1400 0.09 0.15 0.26
#  854x480       24      750  1200  2100 0.08 0.12 0.22
# 1280x720       24     1500  2400  4200 0.07 0.11 0.19
# 1920x1080      24     3000  4800  8400 0.06 0.10 0.17
# 4096x2160      24    10000 16000 28000 0.05 0.08 0.14

# https://developers.google.com/media/vp9/bitrate-modes
