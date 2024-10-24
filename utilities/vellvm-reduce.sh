#!/usr/bin/env bash

help()
{
    echo "Reduce LLVM programs using bugpoint. Compares output between"
    echo "clang and vellvm to determine which test cases are interesting."
    echo
    echo "Usage: $(basename $0) [OPTIONS] <FILE>"
    echo
    echo "Options:"
    echo "[-h | --help]    Print this Help."
    echo "[-i | --input]   Input LLVM file."
    echo "[-o | --output]  Output LLVM file."
    echo "[--clang]        Specify the clang executable to use."
    echo "[--bugpoint]     Specify the bugpoint executable to use."
    echo "[--opt]          Specify the opt executable to use."
    echo "[--vellvm]       Specify the vellvm executable to use."
    echo
    echo "Environment variables:"
    exit 2
}

export LL_OUTPUT=
export LL_INPUT=
export CLANG_EXE=$(which clang)
export BUGPOINT_EXE=$(which bugpoint)
export OPT_EXE=$(which opt)
export VELLVM_EXE=$(PATH=$PATH:. which vellvm)
if [[ $? != "0" ]]; then
    export VELLVM_EXE=
fi;

PARSED_ARGUMENTS=$(getopt -a -n $(basename $0) -o ho:i: -l help,output:,input:,clang:,bugpoint:,opt:,vellvm: -- "$@")
VALID_ARGUMENTS=$?
if [ "$VALID_ARGUMENTS" != "0" ]; then
    help
    exit
fi

eval set -- "$PARSED_ARGUMENTS"
while true; do
    case "$1" in
        -h | --help)
            help; exit;;
        -o | --output)
            export LL_OUTPUT="$2"; shift 2;;
        -i | --input)
            export LL_INPUT="$2"; shift 2;;
        --clang)
            export CLANG_EXE="$2"; shift 2;;
        --bugpoint)
            export BUGPOINT_EXE="$2"; shift 2;;
        --opt)
            export OPT_EXE="$2"; shift 2;;
        --vellvm)
            export VELLVM_EXE="$2"; shift 2;;
        --)
            shift; break;;
        *)
            help; exit;;
    esac
done

if [[ -n $1 && -n $LL_INPUT ]]; then
    echo -e "\e[31mLLVM file specified with -i / --input, but also provided as additional argument to command.\e[0m"
    help
fi

if [[ -z $1 && -z $LL_INPUT ]]; then
    echo -e "\e[31mNeed to supply an LLVM file as input.\e[0m"
    help
fi

if [[ -n $1 && -z $LL_INPUT ]]; then
    export LL_INPUT="$1"
fi

if [[ -z $LL_OUTPUT ]]; then
    export LL_OUTPUT="${LL_INPUT%.ll}-reduced.ll"
fi

if [[ -z $VELLVM_EXE ]]; then
    echo
    echo -e "\e[31m!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\e[0m"
    echo -e "\e[31mCould not find vellvm executable. Please supply manually.\e[0m"
    echo -e "\e[31m!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\e[0m"
    echo
    help
fi

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

EXECUTABLE=$(mktemp)
VELLVM_STDERR=$(mktemp)
VELLVM_STDOUT=$(mktemp)
BUGPOINT_DIR=$(mktemp -d)

__cleanup()
{
    SIGNAL=$1

    [[ -f $EXECUTABLE ]] && rm $EXECUTABLE
    [[ -f $VELLVM_STDERR ]] && rm $VELLVM_STDERR
    [[ -f $VELLVM_STDOUT ]] && rm $VELLVM_STDOUT
    [[ -d $BUGPOINT_DIR ]] && rm -r $BUGPOINT_DIR

    if [[ -n $SIGNAL ]]
    then
        trap $SIGNAL
        kill -${SIGNAL} $$
    fi
}

trap __cleanup EXIT SIGHUP SIGINT SIGQUIT SIGABRT

# Get vellvm return.
"$VELLVM_EXE" -interpret "$LL_INPUT" 2> "$VELLVM_STDERR" 1> "$VELLVM_STDOUT"
VELLVM_EXIT=$?

export VELLVM_ERR=$(cat $VELLVM_STDERR)
if [ $VELLVM_EXIT != 0 ]; then
    # Run with error preserving script...
    echo -e "\e[32mRunning bugscript for vellvm errors...\e[0m"
    bugpoint -compile-custom -compile-command="$SCRIPT_DIR/bugpoint-scripts/vellvm-error-check.sh" -opt-command="$OPT_EXE" "$LL_INPUT"
    llvm-dis bugpoint-reduced-simplified.bc -o "$LL_OUTPUT"
    exit 0
fi

export VELLVM_EXIT_CODE=$(perl -ne '/Program terminated with: .* (\d+)/ and printf $1' "$VELLVM_STDOUT")

# Compile with clang and get exit code...
"$CLANG_EXE" "$LL_INPUT" -o "$EXECUTABLE"
"$EXECUTABLE"
export EXEC_EXIT_CODE=$?

# Run script that checks return codes...
echo -e "\e[32mRunning bugscript for comparing return values between vellvm and clang...\e[0m"
bugpoint -compile-custom -compile-command="$SCRIPT_DIR/bugpoint-scripts/return-value-check.sh" -opt-command="$OPT_EXE" "$LL_INPUT"
llvm-dis bugpoint-reduced-simplified.bc -o "$LL_OUTPUT"

exit 0
