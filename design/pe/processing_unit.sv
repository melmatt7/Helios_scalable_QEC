`timescale 1ns / 1ps

// Right now this code is written targeting syndromes touching the X boundry
// Therefore boundry cost Z , UD , has boundry z UD is the only used parameter

module processing_unit #(
    parameter ADDRESS_WIDTH = 18,  // width of address, e.g. single measurement standard surface code under d <= 15 could be 4bit * 2 = 8bit
    parameter DISTANCE_WIDTH = 6,  // the maximum distance between two nodes should fit into DISTANCE_WIDTH bits
    parameter BOUNDARY_WIDTH = 2,  // usually boundary cost would be 2, so by default 2 bits for boundary cost
    parameter NEIGHBOR_COUNT = 6,  // the direct neighbor of a stabilizer, usually between 2 and 4 for surface code
    parameter FAST_CHANNEL_COUNT = 0,  // CHANNEL_COUNT = NEIGHBOR_COUNT + FAST_CHANNEL_COUNT
    parameter I = 0,
    parameter J = 0,
    parameter K = 0,
    parameter CODE_DISTANCE_X = 4,
    parameter CODE_DISTANCE_Z = 12,
    parameter MEASUREMENT_ROUNDS = 12,
    parameter INIT_BOUNDARY_COST_X = 6,
    parameter INIT_BOUNDARY_COST_Z = 2,
    parameter INIT_BOUNDARY_COST_UD = 2,
    parameter DIRECT_CHANNEL_COUNT = 3
) (
    clk,
    reset,
    // input data. The error syndrome read in STAGE_MEASUREMENT_LOADING
    init_is_error_syndrome,
    // stage indicator
    stage_in,
    // neighbor links
    neighbor_is_fully_grown,
    neighbor_is_odd_cluster,
    neighbor_roots,  // connect to *_old_root_out
    neighbor_increase,  // connect to *_increase
    // direct channels using `blocking_channel`
    direct_out_channels_data_single,
    direct_out_channels_valid,
    direct_out_channels_is_full,
    direct_in_channels_data,
    direct_in_channels_valid,
    direct_in_channels_is_taken,
    // internal states are also published
    old_root,
    updated_root,
    is_error_syndrome,
    is_odd_cluster,
    is_touching_boundary,
    is_odd_cardinality,
    pending_tell_new_root_touching_boundary,
    is_processing
);

`include "../../parameters/parameters.sv"

localparam CHANNEL_COUNT = NEIGHBOR_COUNT + FAST_CHANNEL_COUNT;
localparam CHANNEL_WIDTH = $clog2(CHANNEL_COUNT);  // the index of channel, both neighbor and direct ones
localparam DIRECT_CHANNEL_WIDTH = $clog2(DIRECT_CHANNEL_COUNT);
localparam UNION_MESSAGE_WIDTH = 2 * ADDRESS_WIDTH;  // [old_root, updated_root]
localparam DIRECT_MESSAGE_WIDTH = ADDRESS_WIDTH + 1 + 1;  // [receiver, is_odd_cardinality_root, is_touching_boundary]
localparam PER_DIMENSION_WIDTH = DISTANCE_WIDTH - 1;

input clk;
input reset;
// initialization information, which is read on reset
input init_is_error_syndrome;
// stage indicator
input [STAGE_WIDTH-1:0] stage_in;
// neighbor links using `neighbor_link` module
input [NEIGHBOR_COUNT-1:0] neighbor_is_fully_grown;
input [NEIGHBOR_COUNT-1:0] neighbor_is_odd_cluster;
input [(ADDRESS_WIDTH * NEIGHBOR_COUNT)-1:0] neighbor_roots;  // connect to *_old_root_out
output neighbor_increase;  // connect to *_increase, shared by all neighbors
// direct channels using `blocking_channel`, each message is packed [receiver, is_odd_cardinality_root, is_touching_boundary]
output [DIRECT_MESSAGE_WIDTH-1:0] direct_out_channels_data_single;
output [DIRECT_CHANNEL_COUNT-1:0] direct_out_channels_valid;
input [DIRECT_CHANNEL_COUNT-1:0] direct_out_channels_is_full;
input [(DIRECT_MESSAGE_WIDTH * DIRECT_CHANNEL_COUNT)-1:0] direct_in_channels_data;
input [DIRECT_CHANNEL_COUNT-1:0] direct_in_channels_valid;
output [DIRECT_CHANNEL_COUNT-1:0] direct_in_channels_is_taken;

// internal states
reg [ADDRESS_WIDTH-1:0] address;  // my address
output reg [ADDRESS_WIDTH-1:0] old_root;
output reg [ADDRESS_WIDTH-1:0] updated_root;
reg [STAGE_WIDTH-1:0] last_stage;
reg [STAGE_WIDTH-1:0] stage;
reg [STAGE_WIDTH-1:0] stage_delayed;
output reg is_error_syndrome;
reg has_boundary_x;
reg has_boundary_z;
reg has_boundary_ud;
reg [BOUNDARY_WIDTH-1:0] boundary_cost_x;
reg [BOUNDARY_WIDTH-1:0] boundary_cost_z;
reg [BOUNDARY_WIDTH-1:0] boundary_cost_ud;
output reg is_odd_cluster;
output reg is_touching_boundary;
output reg is_odd_cardinality;
output reg pending_tell_new_root_touching_boundary;
output is_processing;

reg [BOUNDARY_WIDTH-1:0] boundary_increased_x;
reg [BOUNDARY_WIDTH-1:0] boundary_increased_z;
reg [BOUNDARY_WIDTH-1:0] boundary_increased_ud;

reg neighbor_changed;
reg neighbor_changed_delayed;

assign is_processing = neighbor_changed_delayed | neighbor_changed | (|direct_out_channels_valid) | (|direct_in_channels_valid) | pending_direct_message_valid_delayed | my_stored_direct_message_valid;

wire [ADDRESS_WIDTH-1:0] init_address;
assign init_address[ADDRESS_WIDTH-1:PER_DIMENSION_WIDTH*2] = K;
assign init_address[PER_DIMENSION_WIDTH*2-1:PER_DIMENSION_WIDTH] = I;
assign init_address[PER_DIMENSION_WIDTH-1:0] = J;

`define init_has_boundary_x(i, j, k) (0)
`define init_has_boundary_z(i, j, k) ((j==0) || (j==CODE_DISTANCE_Z - 1))
`define init_has_boundary_ud(i, j, k) (k==0 )
wire init_has_boundary_x;
wire init_has_boundary_z;
wire init_has_boundary_ud;
assign init_has_boundary_x = `init_has_boundary_x(I, J, K);
assign init_has_boundary_z = `init_has_boundary_z(I, J, K);
assign init_has_boundary_ud = `init_has_boundary_ud(I, J, K);

wire [BOUNDARY_WIDTH-1:0] init_boundary_cost_x;
wire [BOUNDARY_WIDTH-1:0] init_boundary_cost_z;
wire [BOUNDARY_WIDTH-1:0] init_boundary_cost_ud;
assign init_boundary_cost_x = INIT_BOUNDARY_COST_X;
assign init_boundary_cost_z = INIT_BOUNDARY_COST_Z;
assign init_boundary_cost_ud = INIT_BOUNDARY_COST_UD;

genvar i;

wire is_stage_spread_cluster;
assign is_stage_spread_cluster = (stage == STAGE_SPREAD_CLUSTER);
assign is_stage_spread_cluster_delayed = (stage_delayed == STAGE_SPREAD_CLUSTER);

// create separate local wires for packed arrays, because Vivado doesn't seem to support things like input  logic [0:15] [127:0] mux_in,
// i defined in range [0, CHANNEL_COUNT)
`define compare_solver_addr(i) compare_solver_addrs[((i+1) * ADDRESS_WIDTH) - 1 : (i * ADDRESS_WIDTH)]
`define compare_solver_valid(i) compare_solver_addrs_valid[i]
`define direct_out_valid(i) direct_out_channels_valid[i]
`define direct_out_is_full(i) direct_out_channels_is_full[i]
`define direct_in_data(i) direct_in_channels_data[((i+1) * DIRECT_MESSAGE_WIDTH) - 1 : (i * DIRECT_MESSAGE_WIDTH)]
`define direct_in_data_receiver(i) direct_in_channels_data[((i+1) * DIRECT_MESSAGE_WIDTH) - 1 : (i * DIRECT_MESSAGE_WIDTH) + 2]
`define direct_in_data_is_odd_cardinality(i) direct_in_channels_data[(i * DIRECT_MESSAGE_WIDTH) + 1]
`define direct_in_data_is_touching_boundary(i) direct_in_channels_data[(i * DIRECT_MESSAGE_WIDTH)]
`define direct_in_valid(i) direct_in_channels_valid[i]
`define direct_in_is_taken(i) direct_in_channels_is_taken[i]
// i defined in range [0, NEIGHBOR_COUNT)
`define is_fully_grown(i) neighbor_is_fully_grown[i]
`define neighbor_is_odd_cluster(i) neighbor_is_odd_cluster[i]
`define neighbor_root(i) neighbor_roots[((i+1) * ADDRESS_WIDTH) - 1 : (i * ADDRESS_WIDTH)]
`define channel_addresses_k(idx) channel_addresses[(idx+1)*ADDRESS_WIDTH-1 : idx*ADDRESS_WIDTH+2*PER_DIMENSION_WIDTH]
`define channel_addresses_i(idx) channel_addresses[(idx+1)*ADDRESS_WIDTH-1-PER_DIMENSION_WIDTH : idx*ADDRESS_WIDTH+PER_DIMENSION_WIDTH]
`define channel_addresses_j(idx) channel_addresses[(idx+1)*ADDRESS_WIDTH-1-2*PER_DIMENSION_WIDTH : idx*ADDRESS_WIDTH]

// compare solvers should be a combinational logic that takes multiple addresses and output the smallest one
wire [ADDRESS_WIDTH-1:0] compare_solver_default_addr;
wire [(ADDRESS_WIDTH * CHANNEL_COUNT)-1:0] compare_solver_addrs;
wire [CHANNEL_COUNT-1:0] compare_solver_addrs_valid;
wire [ADDRESS_WIDTH-1:0] compare_solver_result;
reg [ADDRESS_WIDTH-1:0] compare_solver_result_stored;

// tree compare solver
tree_compare_solver #(
    .DATA_WIDTH(ADDRESS_WIDTH),
    .CHANNEL_COUNT(NEIGHBOR_COUNT)
) u_tree_compare_solver (
    .default_value(compare_solver_default_addr),
    .values(compare_solver_addrs),
    .valids(compare_solver_addrs_valid),
    .result(compare_solver_result)
);

// distance solvers should take a target and multiple points and output the nearest point to the target, the multiple points are fixed and could be optimized
wire [ADDRESS_WIDTH-1:0] distance_solver_target;
wire [DIRECT_CHANNEL_WIDTH-1:0] distance_solver_result_idx;
wire [(ADDRESS_WIDTH * DIRECT_CHANNEL_COUNT)-1:0] channel_addresses;

<<<<<<< HEAD:design/pe/processing_unit.sv
=======
<<<<<<< HEAD:distributed_union_find/distributed_union_find.srcs/sources_1/new/processing_unit.sv

=======
>>>>>>> single_fpga_version:design/pe/processing_unit.sv
>>>>>>> multi_mergable:design/pe/processing_unit.sv
tree_distance_3d_solver #(
    .PER_DIMENSION_WIDTH(PER_DIMENSION_WIDTH),
    .CHANNEL_COUNT(DIRECT_CHANNEL_COUNT),
    .I(I),
    .J(J),
    .K(K)
) u_tree_distance_3d_solver (
//    .points(channel_addresses),
    .target(distance_solver_target),
    .result_idx(distance_solver_result_idx)
);

// split messages in channels
localparam CHANNEL_DEPTH = $clog2(CHANNEL_COUNT); //2
localparam DIRECT_CHANNEL_DEPTH = $clog2(DIRECT_CHANNEL_COUNT); //2
localparam CHANNEL_EXPAND_COUNT = 2 ** CHANNEL_DEPTH; //4
localparam DIRECT_CHANNEL_EXPAND_COUNT = 2 ** DIRECT_CHANNEL_DEPTH; //4
localparam CHANNEL_ALL_EXPAND_COUNT = 2 * CHANNEL_EXPAND_COUNT - 1;  // the length of tree structured gathering // 7
localparam DIRECT_CHANNEL_ALL_EXPAND_COUNT = 2 * DIRECT_CHANNEL_EXPAND_COUNT - 1;  // the length of tree structured gathering // 7
wire [DIRECT_CHANNEL_COUNT-1:0] direct_in_channels_data_is_odd_cardinality;
wire [DIRECT_CHANNEL_COUNT-1:0] direct_in_channels_data_is_touching_boundary;
generate
    for (i=0; i < DIRECT_CHANNEL_COUNT; i=i+1) begin: splitting_direct_in_channel_messages
        assign direct_in_channels_data_is_odd_cardinality[i] = `direct_in_data_is_odd_cardinality(i);
        assign direct_in_channels_data_is_touching_boundary[i] = `direct_in_data_is_touching_boundary(i);
    end
endgenerate

// tree structured information gathering for general channels (both union channels and direct channels)
`define CHANNEL_LAYER_WIDTH (2 ** (CHANNEL_DEPTH - 1 - i))
`define CHANNEL_LAYERT_IDX (2 ** (CHANNEL_DEPTH + 1) - 2 ** (CHANNEL_DEPTH - i))
`define CHANNEL_LAST_LAYERT_IDX (2 ** (CHANNEL_DEPTH + 1) - 2 ** (CHANNEL_DEPTH + 1 - i))
`define CHANNEL_CURRENT_IDX (`CHANNEL_LAYERT_IDX + j)
`define CHANNEL_CHILD_1_IDX (`CHANNEL_LAST_LAYERT_IDX + 2 * j)
`define CHANNEL_CHILD_2_IDX (`CHANNEL_CHILD_1_IDX + 1)
localparam CHANNEL_ROOT_IDX = CHANNEL_ALL_EXPAND_COUNT - 1; // 6

`define DIRECT_CHANNEL_LAYER_WIDTH (2 ** (DIRECT_CHANNEL_DEPTH - 1 - i))
`define DIRECT_CHANNEL_LAYERT_IDX (2 ** (DIRECT_CHANNEL_DEPTH + 1) - 2 ** (DIRECT_CHANNEL_DEPTH - i))
`define DIRECT_CHANNEL_LAST_LAYERT_IDX (2 ** (DIRECT_CHANNEL_DEPTH + 1) - 2 ** (DIRECT_CHANNEL_DEPTH + 1 - i))
`define DIRECT_CHANNEL_CURRENT_IDX (`DIRECT_CHANNEL_LAYERT_IDX + j)
`define DIRECT_CHANNEL_CHILD_1_IDX (`DIRECT_CHANNEL_LAST_LAYERT_IDX + 2 * j)
`define DIRECT_CHANNEL_CHILD_2_IDX (`DIRECT_CHANNEL_CHILD_1_IDX + 1)
localparam DIRECT_CHANNEL_ROOT_IDX = DIRECT_CHANNEL_ALL_EXPAND_COUNT - 1; // 6

// prepare variables for sync is_odd_cluster
wire myself_is_odd_cardinality_but_not_touching_boundary;
assign myself_is_odd_cardinality_but_not_touching_boundary = (address == updated_root) && (!is_touching_boundary) && is_odd_cardinality;

// compute `updated_is_odd_cluster`
wire updated_is_odd_cluster;
wire [CHANNEL_ALL_EXPAND_COUNT-1:0] tree_gathering_is_odd_cluster;
generate
    for (i=0; i < CHANNEL_EXPAND_COUNT; i=i+1) begin: pending_is_odd_cluster_gathering_initialization
        if (i < CHANNEL_COUNT) begin
            assign tree_gathering_is_odd_cluster[i] = `neighbor_is_odd_cluster(i);
        end else begin
            assign tree_gathering_is_odd_cluster[i] = 0;
        end
    end
    for (i=0; i < CHANNEL_DEPTH; i=i+1) begin: pending_is_odd_cluster_gathering_election
        genvar j;
        for (j=0; j < `CHANNEL_LAYER_WIDTH; j=j+1) begin: direct_channel_gathering_layer_election
            assign tree_gathering_is_odd_cluster[`CHANNEL_CURRENT_IDX] =
                tree_gathering_is_odd_cluster[`CHANNEL_CHILD_1_IDX] | tree_gathering_is_odd_cluster[`CHANNEL_CHILD_2_IDX];
        end
    end
endgenerate

wire gathered_is_odd_cluster = (|neighbor_is_odd_cluster);
// `define gathered_is_odd_cluster (tree_gathering_is_odd_cluster[CHANNEL_ROOT_IDX])
assign updated_is_odd_cluster = is_odd_cluster | gathered_is_odd_cluster;

// compute `should_broadcast_is_odd_cardinality`
wire should_broadcast_is_odd_cardinality;
assign should_broadcast_is_odd_cardinality = (stage == STAGE_SYNC_IS_ODD_CLUSTER) && 
    ((last_stage != STAGE_SYNC_IS_ODD_CLUSTER) ? (myself_is_odd_cardinality_but_not_touching_boundary) : (updated_is_odd_cluster != is_odd_cluster));

// compute `new_updated_root` based on messages and neighbors, used in `STAGE_SPREAD_CLUSTER` stage
wire [ADDRESS_WIDTH-1:0] new_updated_root;
assign compare_solver_default_addr = updated_root;
generate
    for (i=0; i < CHANNEL_COUNT; i=i+1) begin: compare_new_updated_root
        wire [ADDRESS_WIDTH-1:0] elected_updated_root;
        wire elected_valid;
        if (i < NEIGHBOR_COUNT) begin  // first for neighbors
            // if has union message in the channel, use that one; otherwise use the old_root from neighbor link
            assign elected_valid = `is_fully_grown(i);
            assign elected_updated_root = `neighbor_root(i);
        end else begin  // then for non-neighbors (fast channels only)
            // Unsupported
        end
        assign `compare_solver_addr(i) = elected_updated_root;
        assign `compare_solver_valid(i) = elected_valid;
    end
endgenerate
assign new_updated_root = compare_solver_result;  // combinational logic that computes within a sinlge clock cycle

// Check whether the neighbor data is processing. And hold that singal for one extra cycle
assign neighbor_changed = (is_stage_spread_cluster && (new_updated_root != updated_root)) || should_broadcast_is_odd_cardinality;
always @(posedge clk) begin
    if (reset) begin
        neighbor_changed_delayed <= 0;
    end else begin
        neighbor_changed_delayed <= neighbor_changed;
    end
end

// direct channel local handling
wire [DIRECT_CHANNEL_COUNT-1:0] direct_in_channels_local_handled;
wire [DIRECT_CHANNEL_COUNT-1:0] direct_in_channels_address_matched;
generate
    for (i=0; i < DIRECT_CHANNEL_COUNT; i=i+1) begin: direct_in_channels_local_handling
        assign direct_in_channels_address_matched[i] = (`direct_in_data_receiver(i) == address);
        assign direct_in_channels_local_handled[i] = `direct_in_valid(i) && direct_in_channels_address_matched[i];
    end
endgenerate

// gather `is_odd_cardinality` and `is_touching_boundary` from direct channels in a tree structure to reduce longest path
// elect a message from the direct_in channels that are not locally handled (which one doesn't matter, here we choose the one with smallest index)
// TODO :  simplify this logic. This is hard to understand and may cause multi driven nets
wire [DIRECT_CHANNEL_ALL_EXPAND_COUNT-1:0] tree_gathering_elected_direct_message_valid;
wire [(DIRECT_MESSAGE_WIDTH * DIRECT_CHANNEL_ALL_EXPAND_COUNT)-1:0] tree_gathering_elected_direct_message_data;
`define expanded_elected_direct_message_data(i) tree_gathering_elected_direct_message_data[((i+1) * DIRECT_MESSAGE_WIDTH) - 1 : (i * DIRECT_MESSAGE_WIDTH)]
wire [(DIRECT_CHANNEL_WIDTH * DIRECT_CHANNEL_ALL_EXPAND_COUNT)-1:0] tree_gathering_elected_direct_message_index;
`define expanded_elected_direct_message_index(i) tree_gathering_elected_direct_message_index[((i+1) * DIRECT_CHANNEL_WIDTH) - 1 : (i * DIRECT_CHANNEL_WIDTH)]
generate
    for (i=0; i < DIRECT_CHANNEL_EXPAND_COUNT; i=i+1) begin: direct_channel_gathering_initialization
        if (i < DIRECT_CHANNEL_COUNT) begin
            assign tree_gathering_elected_direct_message_valid[i] = `direct_in_valid(i) && !direct_in_channels_address_matched[i];
            assign `expanded_elected_direct_message_index(i) = i;
            assign `expanded_elected_direct_message_data(i) = `direct_in_data(i);
        end else begin
            assign tree_gathering_elected_direct_message_valid[i] = 0;
        end
    end
    for (i=0; i < DIRECT_CHANNEL_DEPTH; i=i+1) begin: direct_channel_gathering_election
        genvar j;
        for (j=0; j < `DIRECT_CHANNEL_LAYER_WIDTH; j=j+1) begin: direct_channel_gathering_layer_election
            assign tree_gathering_elected_direct_message_valid[`DIRECT_CHANNEL_CURRENT_IDX] = tree_gathering_elected_direct_message_valid[`DIRECT_CHANNEL_CHILD_1_IDX] | tree_gathering_elected_direct_message_valid[`DIRECT_CHANNEL_CHILD_2_IDX];
            assign `expanded_elected_direct_message_index(`DIRECT_CHANNEL_CURRENT_IDX) = tree_gathering_elected_direct_message_valid[`DIRECT_CHANNEL_CHILD_1_IDX] ? (
                `expanded_elected_direct_message_index(`DIRECT_CHANNEL_CHILD_1_IDX)
            ) : (
                `expanded_elected_direct_message_index(`DIRECT_CHANNEL_CHILD_2_IDX)
            );
            assign `expanded_elected_direct_message_data(`DIRECT_CHANNEL_CURRENT_IDX) = tree_gathering_elected_direct_message_valid[`DIRECT_CHANNEL_CHILD_1_IDX] ? (
                `expanded_elected_direct_message_data(`DIRECT_CHANNEL_CHILD_1_IDX)
            ) : (
                `expanded_elected_direct_message_data(`DIRECT_CHANNEL_CHILD_2_IDX)
            );
        end
    end
endgenerate
`define gathered_is_odd_cardinality (^(direct_in_channels_local_handled & direct_in_channels_data_is_odd_cardinality))
`define gathered_is_touching_boundary (|(direct_in_channels_local_handled & direct_in_channels_data_is_touching_boundary))
`define gathered_elected_direct_message_valid (tree_gathering_elected_direct_message_valid[DIRECT_CHANNEL_ROOT_IDX])
`define gathered_elected_direct_message_index (`expanded_elected_direct_message_index(DIRECT_CHANNEL_ROOT_IDX))
`define gathered_elected_direct_message_data (`expanded_elected_direct_message_data(DIRECT_CHANNEL_ROOT_IDX))

// compute `updated_is_touching_boundary`
wire updated_is_touching_boundary;
assign updated_is_touching_boundary = is_touching_boundary 
    || (has_boundary_z && (boundary_increased_z == boundary_cost_z)) 
    || (has_boundary_ud && (boundary_increased_ud == boundary_cost_ud))
    || `gathered_is_touching_boundary;

// compute `updated_is_odd_cardinality`
wire updated_is_odd_cardinality;
assign updated_is_odd_cardinality = is_odd_cardinality ^ `gathered_is_odd_cardinality;

// compute `intermediate_pending_tell_new_root_cardinality` and `intermediate_pending_tell_new_root_touching_boundary`
wire intermediate_pending_tell_new_root_cardinality;
wire intermediate_pending_tell_new_root_touching_boundary;
assign intermediate_pending_tell_new_root_cardinality = 
    new_updated_root != updated_root && is_error_syndrome ;
assign intermediate_pending_tell_new_root_touching_boundary = 
     ((new_updated_root != updated_root && updated_is_touching_boundary) || (updated_is_touching_boundary != is_touching_boundary));


wire pending_message_sent_successfully;

// decide which message to send
wire pending_direct_message_valid;
wire [DIRECT_MESSAGE_WIDTH-1:0] pending_direct_message;
wire intermediate_buffer_is_full;
wire pending_direct_message_valid_delayed;
wire [DIRECT_MESSAGE_WIDTH-1:0] pending_direct_message_delayed;
wire intermediate_buffer_is_taken;
wire intermediatre_initialize;
wire intermediate_message_sent_sucessfully;
assign intermediatre_initialize = stage == STAGE_MEASUREMENT_LOADING;
assign intermediate_message_sent_sucessfully = pending_direct_message_valid && !intermediate_buffer_is_full;

blocking_channel #(
    .WIDTH(DIRECT_MESSAGE_WIDTH) // width of data
) intermediate_stage (
    .in_data(pending_direct_message),
    .in_valid(pending_direct_message_valid),
    .in_is_full(intermediate_buffer_is_full),
    .out_data(pending_direct_message_delayed),
    .out_valid(pending_direct_message_valid_delayed),
    .out_is_taken(pending_message_sent_successfully),
    .clk(clk),
    .reset(reset),
    .initialize(intermediatre_initialize)
);

reg my_stored_direct_message_valid;
reg [DIRECT_MESSAGE_WIDTH-1:0] my_stored_direct_message;

assign is_processing = union_out_channels_valid | (|union_in_channels_valid) | (|direct_out_channels_valid) | (|direct_in_channels_valid) | pending_direct_message_valid_delayed | my_stored_direct_message_valid;

`define pending_direct_message_receiver (pending_direct_message_delayed[DIRECT_MESSAGE_WIDTH-1:2])
wire generate_my_direct_message;
assign generate_my_direct_message = intermediate_pending_tell_new_root_cardinality || intermediate_pending_tell_new_root_touching_boundary;

assign pending_direct_message_valid = (`gathered_elected_direct_message_valid || my_stored_direct_message_valid);
// assign pending_direct_message_valid = (generate_my_direct_message || `gathered_elected_direct_message_valid || my_stored_direct_message_valid);
assign pending_direct_message = `gathered_elected_direct_message_valid ? (
    `gathered_elected_direct_message_data ) : (
        my_stored_direct_message
);

always@(posedge clk) begin
    if (reset) begin
        my_stored_direct_message_valid <= 0;
    end else begin
        if (intermediatre_initialize) begin
            my_stored_direct_message_valid <= 0;
        end else if (generate_my_direct_message && is_stage_spread_cluster) begin
            my_stored_direct_message_valid <= 1;
        end else if (intermediate_message_sent_sucessfully && !`gathered_elected_direct_message_valid) begin
            my_stored_direct_message_valid <= 0;
        end
    end
end

always@(posedge clk) begin
    if (generate_my_direct_message) begin
        my_stored_direct_message <= { new_updated_root, intermediate_pending_tell_new_root_cardinality, intermediate_pending_tell_new_root_touching_boundary };
    end
end 
// decide the nearest port to send out the pending message, get the result from `distance_solver_result_idx`
assign distance_solver_target = `pending_direct_message_receiver;
`define best_channel_for_pending_message_idx distance_solver_result_idx

// check if it can be sent successfully
wire [DIRECT_CHANNEL_ALL_EXPAND_COUNT-1:0] tree_gathering_pending_message_sent_successfully;
generate
    for (i=0; i < DIRECT_CHANNEL_EXPAND_COUNT; i=i+1) begin: pending_message_sent_successfully_gathering_initialization
        if (i < DIRECT_CHANNEL_COUNT) begin
            assign tree_gathering_pending_message_sent_successfully[i] = (i == `best_channel_for_pending_message_idx) ? (
                !`direct_out_is_full(i)
            ) : 0;
        end else begin
            assign tree_gathering_pending_message_sent_successfully[i] = 0;
        end
    end
    for (i=0; i < DIRECT_CHANNEL_DEPTH; i=i+1) begin: pending_message_sent_successfully_gathering_election
        genvar j;
        for (j=0; j < `DIRECT_CHANNEL_LAYER_WIDTH; j=j+1) begin: direct_channel_gathering_layer_election
            assign tree_gathering_pending_message_sent_successfully[`DIRECT_CHANNEL_CURRENT_IDX] =
                tree_gathering_pending_message_sent_successfully[`DIRECT_CHANNEL_CHILD_1_IDX] | tree_gathering_pending_message_sent_successfully[`DIRECT_CHANNEL_CHILD_2_IDX];
        end
    end
endgenerate
`define gathered_pending_message_sent_successfully (tree_gathering_pending_message_sent_successfully[DIRECT_CHANNEL_ROOT_IDX])
assign pending_message_sent_successfully = `gathered_pending_message_sent_successfully && pending_direct_message_valid_delayed;

// update the states
wire new_pending_tell_new_root_cardinality;
wire new_pending_tell_new_root_touching_boundary;
assign new_pending_tell_new_root_cardinality = intermediate_pending_tell_new_root_cardinality && !intermediate_message_sent_sucessfully;
assign new_pending_tell_new_root_touching_boundary = intermediate_pending_tell_new_root_touching_boundary && !intermediate_message_sent_sucessfully;

// send the message
assign direct_out_channels_data_single = pending_direct_message_delayed;
wire not_addressed_to_me;
assign not_addressed_to_me = `pending_direct_message_receiver != address;
generate
    for (i=0; i < DIRECT_CHANNEL_COUNT; i=i+1) begin: sending_direct_message
        assign `direct_out_valid(i) = is_stage_spread_cluster_delayed && pending_direct_message_valid_delayed && (i == `best_channel_for_pending_message_idx) && not_addressed_to_me;
    end
endgenerate

// take the direct message from channel
generate
    for (i=0; i < DIRECT_CHANNEL_COUNT; i=i+1) begin: taking_direct_message
        assign `direct_in_is_taken(i) = is_stage_spread_cluster && 
            (((i == `gathered_elected_direct_message_index) && `gathered_elected_direct_message_valid  && intermediate_message_sent_sucessfully) || 
                direct_in_channels_local_handled[i]);  // either brokerd this message or handled locally
    end
endgenerate

// increase neighbor link in STAGE_GROW_BOUNDARY stage
assign neighbor_increase = is_odd_cluster && (stage == STAGE_GROW_BOUNDARY) && (last_stage != STAGE_GROW_BOUNDARY);

// state machine
always @(posedge clk) begin
    if (reset) begin
        address <= init_address; // constant per PU
        old_root <= init_address; // constant per PU
        updated_root <= init_address; // constant per PU
        last_stage <= STAGE_IDLE;
        is_error_syndrome <= 0;
        has_boundary_x <= init_has_boundary_x; // constant per PU
        has_boundary_z <= init_has_boundary_z; // constant per PU
        has_boundary_ud <= init_has_boundary_ud; // constant per PU
        boundary_cost_x <= init_boundary_cost_x; // constant per PU
        boundary_cost_z <= init_boundary_cost_z; // constant per PU
        boundary_cost_ud <= init_boundary_cost_ud; // constant per PU
        boundary_increased_x <= 0;
        boundary_increased_z <= 0;
        boundary_increased_ud <= 0;
        is_odd_cluster <= 0;
        is_touching_boundary <= 0;
        is_odd_cardinality <= 0;
    end else begin
        last_stage <= stage;  // record last stage
        if (stage == STAGE_IDLE) begin
            // PUs do nothing
        end else if (stage == STAGE_SPREAD_CLUSTER) begin
            is_touching_boundary <= updated_is_touching_boundary;
            is_odd_cardinality <= updated_is_odd_cardinality;
            updated_root <= new_updated_root;
            is_odd_cluster <= 0;
        end else if (stage == STAGE_GROW_BOUNDARY) begin
            // only gives a trigger to neighbor links
            // see `assign neighbor_increase = !reset && is_odd_cluster && (stage == STAGE_GROW_BOUNDARY) && (last_stage != STAGE_GROW_BOUNDARY);`
            if (is_odd_cluster && last_stage != STAGE_GROW_BOUNDARY) begin
                // only trigger once when set to STAGE_GROW_BOUNDARY
                if (has_boundary_x && (boundary_increased_x < boundary_cost_x)) begin
                    boundary_increased_x <= boundary_increased_x + 1;
                end
                if (has_boundary_z && (boundary_increased_z < boundary_cost_z)) begin
                    boundary_increased_z <= boundary_increased_z + 1;
                end
                if (has_boundary_ud && (boundary_increased_ud < boundary_cost_ud)) begin
                    boundary_increased_ud <= boundary_increased_ud + 1;
                end
            end
        end else if (stage == STAGE_SYNC_IS_ODD_CLUSTER) begin
            if (last_stage != STAGE_SYNC_IS_ODD_CLUSTER) begin
                // first set them all to even cluster, if it's not itself odd cardinality but not touching boundary
                is_odd_cluster <= myself_is_odd_cardinality_but_not_touching_boundary;
                old_root <= updated_root;  // update old_root
            end else begin
                is_odd_cluster <= updated_is_odd_cluster;
            end
        end else if (stage == STAGE_MEASUREMENT_LOADING) begin
            address <= init_address;
            old_root <= init_address;
            updated_root <= init_address;
            last_stage <= STAGE_IDLE;
            is_error_syndrome <= init_is_error_syndrome;
            has_boundary_x <= init_has_boundary_x; // constant per PU
            has_boundary_z <= init_has_boundary_z; // constant per PU
            has_boundary_ud <= init_has_boundary_ud; // constant per PU
            boundary_cost_x <= init_boundary_cost_x; // constant per PU
            boundary_cost_z <= init_boundary_cost_z; // constant per PU
            boundary_cost_ud <= init_boundary_cost_ud; // constant per PU
            boundary_increased_x <= 0;
            boundary_increased_z <= 0;
            boundary_increased_ud <= 0;
            is_odd_cluster <= init_is_error_syndrome;
            is_touching_boundary <= 0;
            is_odd_cardinality <= init_is_error_syndrome;
        end
    end
end

always @(posedge clk) begin
    if (reset) begin
        stage <= STAGE_IDLE;
        stage_delayed <= STAGE_IDLE;
    end else begin
        stage <= stage_in;
        stage_delayed <= stage;
    end
end

endmodule
