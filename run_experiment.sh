#!/bin/bash

# This script automates running key-value store benchmarks and generating graphs.
#
# USAGE:
#   ./run_experiment.sh            (Compiles, runs all experiments, then generates graphs)
#   ./run_experiment.sh --graph-only (Graphs from CSVs in the current directory)
#   ./run_experiment.sh --graph-only --path /path/to/results (Graphs from CSVs in a specific directory)
#   ./run_experiment.sh --help       (Displays this usage information)

# --- Default Experiment Parameters ---
# These are used only when running new experiments.
THREAD_COUNTS=(1 2 4 8)
BATCH_SIZES=($(seq 100 100 1000))
TOTAL_OPS=10000
EXIT_CODE="abc"
DB_FILE="/tmp/temp.db"
LOG_FILE="/tmp/temp_logfile.txt"
THROUGHPUT_FILE="results_throughput.csv"
DURATION_FILE="results_duration.csv"


# --- Function to run the full experiment suite ---
run_experiments() {
    # --- Build binaries first to ensure consistent timing ---
    echo "Building server and benchmark binaries in release mode..."
    cargo build --release --bin server
    cargo build --release --bin benchmark
    echo "Build complete."
    echo ""

    # --- Prepare results files ---
    # Dynamically create the header row based on the thread counts.
    HEADER="batch_size"
    for T in "${THREAD_COUNTS[@]}"; do
        HEADER="$HEADER,${T}_threads"
    done
    echo "$HEADER" > $THROUGHPUT_FILE
    echo "$HEADER" > $DURATION_FILE
    echo "Results will be saved to $THROUGHPUT_FILE and $DURATION_FILE"
    echo ""

    # --- Main Experiment Loop ---
    # The outer loop iterates through each batch size, which will form the rows of the CSVs.
    for BATCH_SIZE in "${BATCH_SIZES[@]}"; do
        # Start building the CSV rows, beginning with the current batch size.
        THROUGHPUT_ROW="$BATCH_SIZE"
        DURATION_ROW="$BATCH_SIZE"
        echo "--- Processing Batch Size: $BATCH_SIZE ---"

        # The inner loop iterates through each thread count for the given batch size.
        for THREADS in "${THREAD_COUNTS[@]}"; do
            # Calculate the number of operations each thread should perform.
            OPS_PER_THREAD=$((TOTAL_OPS / THREADS))

            echo "  Running with $THREADS threads ($OPS_PER_THREAD ops/thread)..."

            # Clean up previous run's files to ensure a fresh start.
            rm -f $DB_FILE $LOG_FILE

            # Start the server in the background.
            ./target/release/server --dbfile $DB_FILE --logfile $LOG_FILE --exit-code $EXIT_CODE &> /dev/null &
            SERVER_PID=$!
            sleep 2 # Give the server a moment to start.

            # Run the benchmark client and capture its output.
            CLIENT_OUTPUT=$(./target/release/benchmark --threads $THREADS --ops $OPS_PER_THREAD --batch-size $BATCH_SIZE --exit-code $EXIT_CODE)
            wait $SERVER_PID # Wait for the server to shut down.

            # Extract the throughput and duration values from the client's output.
            THROUGHPUT=$(echo "$CLIENT_OUTPUT" | grep "Throughput:" | awk '{print $2}')
            DURATION=$(echo "$CLIENT_OUTPUT" | grep "Total Duration:" | awk '{print $3}')

            # Append the values to their respective CSV row strings.
            THROUGHPUT_ROW="$THROUGHPUT_ROW,$THROUGHPUT"
            DURATION_ROW="$DURATION_ROW,$DURATION"
            
            echo "    -> Throughput: $THROUGHPUT M req/s, Duration: $DURATION s"
        done

        # After testing all thread counts, write the complete rows to the results files.
        echo "$THROUGHPUT_ROW" >> $THROUGHPUT_FILE
        echo "$DURATION_ROW" >> $DURATION_FILE
        echo ""
    done

    echo "---------------------------------"
    echo "Experiment complete."
}

# --- Function to generate graphs from existing CSV files ---
generate_graphs() {
    # Check if termgraph is installed.
    if ! termgraph --version &> /dev/null; then
        echo "termgraph not found. Skipping graph generation."
        echo "To install, run: pip3 install termgraph"
        exit 0
    fi

    # Check if result files exist.
    if [ ! -f "$THROUGHPUT_FILE" ] || [ ! -f "$DURATION_FILE" ]; then
        echo "Error: Result files ($THROUGHPUT_FILE, $DURATION_FILE) not found."
        echo "Please run the experiment first without the --graph-only flag."
        exit 1
    fi

    echo "termgraph is installed. Generating graphs..."

    # --- Dynamically determine thread counts from CSV header for color selection ---
    HEADER=$(head -n 1 "$THROUGHPUT_FILE")
    # Extracts "1_threads,2_threads,..." -> "1 2 ..." and creates an array
    GRAPH_THREAD_COUNTS=($(echo "$HEADER" | cut -d',' -f2- | sed 's/_threads//g' | sed 's/,/ /g'))

    # --- Prepare colors for termgraph ---
    ALL_COLORS=('red' 'green' 'blue' 'magenta' 'yellow' 'cyan' 'black')
    NUM_THREADS=${#GRAPH_THREAD_COUNTS[@]}
    USED_COLORS=("${ALL_COLORS[@]:0:$NUM_THREADS}")
    # Join the selected colors with a comma for the brace expansion string.
    COLOR_ARGS_STRING=$(IFS=,; echo "${USED_COLORS[*]}")

    # --- Create temporary files for graphing and execute commands ---
    TEMP_THROUGHPUT_FILE="temp_results_throughput.csv"
    TEMP_DURATION_FILE="temp_results_duration.csv"

    # Modify the header for termgraph and generate the throughput graph.
    sed '1s/batch_size,/@ /' "$THROUGHPUT_FILE" > "$TEMP_THROUGHPUT_FILE"
    COMMAND_THROUGHPUT="termgraph '$TEMP_THROUGHPUT_FILE' --color {$COLOR_ARGS_STRING} --title 'Batch Size Vs Throughput'"
    echo ""
    echo "--- Batch Size Vs Throughput ---"
    eval $COMMAND_THROUGHPUT
    
    # Modify the header for termgraph and generate the duration graph.
    sed '1s/batch_size,/@ /' "$DURATION_FILE" > "$TEMP_DURATION_FILE"
    COMMAND_DURATION="termgraph '$TEMP_DURATION_FILE' --color {$COLOR_ARGS_STRING} --title 'Batch Size Vs Duration'"
    echo ""
    echo "--- Batch Size Vs Duration ---"
    eval $COMMAND_DURATION

    # Clean up the temporary files.
    rm -f "$TEMP_THROUGHPUT_FILE" "$TEMP_DURATION_FILE"
}


# --- Main script logic ---
# A more robust argument parsing loop.
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --graph-only)
        GRAPH_ONLY=true
        shift # past argument
        ;;
        --path)
        RESULTS_PATH="$2"
        shift # past argument
        shift # past value
        ;;
        --help)
        # Extract the usage instructions from the script's own comments.
        grep -A 4 '^# USAGE:' "$0" | sed 's/^# //'
        exit 0
        ;;
        *)    # unknown option
        shift # past argument
        ;;
    esac
done

# If a custom path is provided, update the file variables.
if [ -n "$RESULTS_PATH" ]; then
    THROUGHPUT_FILE="$RESULTS_PATH/results_throughput.csv"
    DURATION_FILE="$RESULTS_PATH/results_duration.csv"
fi

if [ "$GRAPH_ONLY" = true ]; then
    generate_graphs
else
    run_experiments
    generate_graphs
fi
