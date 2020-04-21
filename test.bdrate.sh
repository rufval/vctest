set -eu -o pipefail

#
# BD-Rate evaluation example
#
[ "$#" -gt 0 ] && ./core/testbench.sh -h && exit

#CODECS="ashevc x265 kvazaar kingsoft intel_sw intel_hw h265demo h264demo"
CODECS="ashevc x265 kvazaar kingsoft intel_sw intel_hw h265demo"

# 4 point required
case 1 in
	0)	PRMS=" 60    80  120   150"
		VECTORS="akiyo_qcif.yuv foreman_qcif.yuv" # fast check
	;;
	1)	PRMS="500  1000 1500  2000"
		VECTORS="\
			tears_of_steel_1280x720_24.webm.yuv\
			FourPeople_1280x720_30.y4m.yuv\
			stockholm_ter_1280x720_30.y4m.yuv\
			vidyo4_720p_30fps.y4m.yuv\
		"
	;;
esac

readonly timestamp=$(date "+%Y.%m.%d-%H.%M.%S")
readonly dirLog=out/bdrate
readonly report="$dirLog/bdrate_$timestamp.log"

# Generate logs
VECTORS=$(for i in $VECTORS; do echo "vectors/$i"; done)
./core/testbench.sh -i "$VECTORS" -c "$CODECS" -p "$PRMS" -d "$dirLog/out" -o "$report"

# Calcultate BD-rate
echo "$timestamp" >> bdrate.log
./core/bdrate.sh -c ashevc -i $dirLog/bdrate_${timestamp}_kw.log | tee -a bdrate.log
