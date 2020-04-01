#!/bin/bash

#
##
### Environment and Bash sanity.
##
#
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]
then
	echo "Sorry, you need at least bash 4.x to use ${0}." >&2
	exit 1
fi

set -e # Exit if any subcommand or pipeline returns a non-zero exit status.
set -u # Raise exception if variable is unbound. Combined with set -e will halt execution when an unbound variable is encountered.

umask 0027

# Env vars.
export TMPDIR="${TMPDIR:-/tmp}" # Default to /tmp if $TMPDIR was not defined.
SCRIPT_NAME="$(basename "${0}")"
SCRIPT_NAME="${SCRIPT_NAME%.*sh}"
INSTALLATION_DIR="$(cd -P "$(dirname "${0}")/.." && pwd)"
LIB_DIR="${INSTALLATION_DIR}/lib"
CFG_DIR="${INSTALLATION_DIR}/etc"
HOSTNAME_SHORT="$(hostname -s)"
ROLE_USER="$(whoami)"
REAL_USER="$(logname 2>/dev/null || echo 'no login name')"

#
##
### Functions.
##
#

if [[ -f "${LIB_DIR}/sharedFunctions.bash" && -r "${LIB_DIR}/sharedFunctions.bash" ]]
then
	# shellcheck source=lib/sharedFunctions.bash
	source "${LIB_DIR}/sharedFunctions.bash"
else
	printf '%s\n' "FATAL: cannot find or cannot access sharedFunctions.bash"
	exit 1
fi

function showHelp() {
	#
	# Display commandline help on STDOUT.
	#
	cat <<EOH
======================================================================================================================
Script to calculate concordance between SNV calls from NGS and Array data.

Usage:

	$(basename "${0}") OPTIONS

Options:

	-h	Show this help.
	-g	group
	-l	Log level.
		Must be one of TRACE, DEBUG, INFO (default), WARN, ERROR or FATAL.

Config and dependencies:

	This script needs 3 config files, which must be located in ${CFG_DIR}:
		1. <group>.cfg     for the group specified with -g
		2. <host>.cfg        for this server. E.g.:"${HOSTNAME_SHORT}.cfg"
		3. sharedConfig.cfg  for all groups and all servers.
	In addition the library sharedFunctions.bash is required and this one must be located in ${LIB_DIR}.

======================================================================================================================

EOH
	trap - EXIT
	exit 0
}

#
##
### Main.
##
#

#
# Get commandline arguments.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Parsing commandline arguments ..."
while getopts ":g:l:	h" opt
do
	case "${opt}" in
		h)
			showHelp
			;;
		g)
			GROUP="${OPTARG}"
			;;
		l)
			l4b_log_level="${OPTARG^^}"
			l4b_log_level_prio="${l4b_log_levels["${l4b_log_level}"]}"
			;;
		\?)
			log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" '1' "Invalid option -${OPTARG}. Try $(basename "${0}") -h for help."
			;;
		:)
			log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" '1' "Option -${OPTARG} requires an argument. Try $(basename "${0}") -h for help."
			;;
		*)
			log4Bash 'FATAL' "${LINENO}" "${FUNCNAME[0]:-main}" '1' "Unhandled option. Try $(basename "${0}") -h for help."
			;;	esac
done

#
# Check commandline options.
#
if [[ -z "${GROUP:-}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a group with -g'
fi

#
# Source config files.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config files ..."
declare -a configFiles=(
	"${CFG_DIR}/${GROUP}.cfg"
	"${CFG_DIR}/${HOSTNAME_SHORT}.cfg"
	"${CFG_DIR}/sharedConfig.cfg"
	"${CFG_DIR}/ConcordanceCheck.cfg"
	"${HOME}/molgenis.cfg"
)

for configFile in "${configFiles[@]}"; do 
	if [[ -f "${configFile}" && -r "${configFile}" ]]
	then
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config file ${configFile} ..."
		#
		# In some Bash versions the source command does not work properly with process substitution.
		# Therefore we source a first time with process substitution for proper error handling
		# and a second time without just to make sure we can use the content from the sourced files.
		#
		# Disable shellcheck code syntax checking for config files.
		# shellcheck source=/dev/null
		mixed_stdouterr=$(source "${configFile}" 2>&1) || log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" "${?}" "Cannot source ${configFile}."
		# shellcheck source=/dev/null
		source "${configFile}"  # May seem redundant, but is a mandatory workaround for some Bash versions.
	else
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "Config file ${configFile} missing or not accessible."
	fi
done

#
# Make sure to use an account for cron jobs and *without* write access to prm storage.
#

if [[ "${ROLE_USER}" != "${ATEAMBOTUSER}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "This script must be executed by user ${ATEAMBOTUSER}, but you are ${ROLE_USER} (${REAL_USER})."
fi

lockFile="${TMP_ROOT_DIR}/logs/${SCRIPT_NAME}.lock"
thereShallBeOnlyOne "${lockFile}"
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Successfully got exclusive access to lock file ${lockFile} ..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${TMP_ROOT_DIR}/logs ..."

module load "${htsLibVersion}"
module load "${compareGenotypeCallsVersion}"
module load "${bedToolsVersion}"
module list


concordanceDir="/groups/${GROUP}/${TMP_LFS}/concordance/"
ngsVcfDir="${concordanceDir}/ngs/"
arrayVcfDir="${concordanceDir}/array/"

while IFS= read -r -d '' sampleSheet
do
	echo "______________________________________________________________________________" ## remove when script is finished
	concordanceCheckId=$(basename "${sampleSheet}" .sampleId.txt)
	if [ ! -f "${concordanceDir}/jobs/${concordanceCheckId}.sh" ]
	then

		touch "${concordanceDir}/logs/${concordanceCheckId}.ConcordanceCheck.started"
		arrayId=$(sed 1d "${sampleSheet}" | awk 'BEGIN {FS="\t"}{print $1}')
		arrayVcf="${arrayId}.FINAL.vcf"
		arrayFileLocation=$(sed 1d "${sampleSheet}" | awk 'BEGIN {FS="\t"}{print $3}')
		rsync -av --copy-links "${arrayFileLocation}" "${arrayVcfDir}"
		ngsId=$(sed 1d "${sampleSheet}" | awk 'BEGIN {FS="\t"}{print $2}')
		ngsVcf="${ngsId}.final.vcf.gz"
		ngsFileLocation=$(sed 1d "${sampleSheet}" | awk 'BEGIN {FS="\t"}{print $4}')
		rsync -av --copy-links "${ngsFileLocation}" "${ngsVcfDir}"

		bedType="$(zcat "${ngsVcfDir}/${ngsVcf}" | grep -m 1 -o -P 'intervals=\[[^\]]*.bed\]' | cut -d [ -f2 | cut -d ] -f1)"
		bedDir="$(dirname "${bedType}")"
		bedFile="${bedDir}/captured.merged.bed"

		mkdir -p "${concordanceDir}/tmp/${concordanceCheckId}/"

		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Calculating concordance over ${ngsVcf} compared to ${arrayVcf}"
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Using ${bedFile} to intersect the array vcf file"
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Output file name: ${concordanceCheckId}"

		##remove indel-calls from ngs-vcf
		zcat "${ngsVcfDir}/${ngsVcf}" | grep '^#' > "${concordanceDir}/tmp/${concordanceCheckId}/${ngsId}.FINAL.vcf"
		zcat "${ngsVcfDir}/${ngsVcf}" | grep -v '^#' | awk '{if (length($4)<2 && length($5)<2 ){print $0}}' >> "${concordanceDir}/tmp/${concordanceCheckId}/${ngsId}.FINAL.vcf"

		bgzip -c "${concordanceDir}/tmp/${concordanceCheckId}/${ngsId}.FINAL.vcf" > "${concordanceDir}/tmp/${concordanceCheckId}/${ngsId}.FINAL.vcf.gz"
		tabix -p vcf "${concordanceDir}/tmp/${concordanceCheckId}/${ngsId}.FINAL.vcf.gz"

		if bedtools intersect -a "${arrayVcfDir}/${arrayVcf}" -b "${bedFile}" -header  > "${concordanceDir}/tmp/${concordanceCheckId}/${arrayId}.FINAL.ExonFiltered.vcf"
		then
			echo ""
		else
			'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "There is something wrong while running bedtools intersect"
		fi
		
cat << EOH > "${concordanceDir}/jobs/${concordanceCheckId}.sh"
#!/bin/bash
#SBATCH --job-name=Concordance_${arrayId}
#SBATCH --output=${concordanceDir}/jobs/${arrayId}.out
#SBATCH --error=${concordanceDir}/jobs/${arrayId}.err
#SBATCH --time=05:59:00
#SBATCH --cpus-per-task 1
#SBATCH --mem 10gb
#SBATCH --open-mode=append
#SBATCH --export=NONE
#SBATCH --get-user-env=60L
	module load "${htsLibVersion}"
	module load "${compareGenotypeCallsVersion}"
	module load "${bedToolsVersion}"
	bgzip -c "${concordanceDir}/tmp/${concordanceCheckId}/${arrayId}.FINAL.ExonFiltered.vcf" > "${concordanceDir}/tmp/${concordanceCheckId}/${arrayId}.FINAL.ExonFiltered.vcf.gz"
	tabix -p vcf "${concordanceDir}/tmp/${concordanceCheckId}/${arrayId}.FINAL.ExonFiltered.vcf.gz"

	java -XX:ParallelGCThreads=1 -Djava.io.tmpdir="${concordanceDir}/temp/" -Xmx9g -jar ${EBROOTCOMPAREGENOTYPECALLS}/CompareGenotypeCalls.jar \
	-d1 "${concordanceDir}/tmp/${concordanceCheckId}/${arrayId}.FINAL.ExonFiltered.vcf.gz" \
	-D1 VCF \
	-d2 "${concordanceDir}/tmp/${concordanceCheckId}/${ngsId}.FINAL.vcf.gz" \
	-D2 VCF \
	-ac \
	--sampleMap "${sampleSheet}" \
	-o "${concordanceDir}/tmp/${concordanceCheckId}" \
	-sva

	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "moving ${concordanceDir}/tmp/${concordanceCheckId}.sample to ${concordanceDir}/results/"
	mv "${concordanceDir}/tmp/${concordanceCheckId}.sample" "${concordanceDir}/results/"
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "moving ${concordanceDir}/tmp/${concordanceCheckId}.variants to ${concordanceDir}/results/"
	mv "${concordanceDir}/tmp/${concordanceCheckId}.variants" "${concordanceDir}/results/"

	echo "finished"
	mv "/groups/${GROUP}/${TMP_LFS}/concordance/logs/${concordanceCheckId}.ConcordanceCheck."{started,finished}
	mv "${concordanceDir}/jobs/${concordanceCheckId}.sh."{started,finished} 
EOH
	fi
	
	if [[ ! -f "${concordanceDir}/jobs/${concordanceCheckId}.sh.started" ]] && [[ ! -f "${concordanceDir}/jobs/${concordanceCheckId}.sh.finished" ]]
	then
		sbatch "${concordanceDir}/jobs/${concordanceCheckId}.sh"
		touch "${concordanceDir}/jobs/${concordanceCheckId}.sh.started"
	fi
done < <(find "${concordanceDir}/samplesheets/" -type f -iname "*sampleId.txt") 
trap - EXIT
exit 0

