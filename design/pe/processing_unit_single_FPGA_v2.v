`timescale 1ns / 1ps

// This PEs are written for Z type ancillas

module processing_unit #(
    parameter PER_DIM_BIT_WIDTH = 3,
    parameter BOUNDARY_BIT_WIDTH = 2,
    parameter NEIGHBOR_COUNT = 6,
    parameter ADDRESS = 0, // M,X,Z, address
    parameter CODE_DISTANCE_X = 5,
    parameter CODE_DISTANCE_Z = 4
) (
    clk,
    reset,
    measurement,
    global_stage,

    neighbor_fully_grown,
    neighbor_root,
    neighbor_parent_vector,
    neighbor_increase,
    neighbor_is_boundary,

    parent_odd,
    parent_vector,

    child_cluster_parity,
    child_touching_boundary,

    cluster_parity,
    cluster_touching_boundary,

    odd,
    root,
    busy
);

`include "../../parameters/parameters.sv"

localparam ADDRESS_WIDTH = 3*PER_DIM_BIT_WIDTH;


input clk;
input reset;
input measurement;
input [STAGE_WIDTH-1:0] global_stage;

input [NEIGHBOR_COUNT-1:0] neighbor_fully_grown;
input [NEIGHBOR_COUNT*ADDRESS_WIDTH-1:0] neighbor_root;
input [NEIGHBOR_COUNT-1:0] neighbor_parent_vector;
input [NEIGHBOR_COUNT-1:0] neighbor_is_boundary;
output neighbor_increase;

input [NEIGHBOR_COUNT-1:0] parent_odd;
input [NEIGHBOR_COUNT - 1:0] child_cluster_parity;
input [NEIGHBOR_COUNT - 1:0] child_touching_boundary;

output reg [ADDRESS_WIDTH-1:0] parent_vector;
output reg cluster_parity;
output reg cluster_touching_boundary;

output reg odd;
output reg [ADDRESS_WIDTH-1:0] root;
output reg busy;

reg [STAGE_WIDTH - 1 : 0] stage;
reg [STAGE_WIDTH - 1 : 0] last_stage;

// stage is always equal to global_stage
always@(posedge clk) begin
    if(reset) begin
        stage <= STAGE_IDLE;
        last_stage <= STAGE_IDLE;
    end else begin
        stage <= global_stage;
        last_stage <= stage;
    end
end

// Load the measurement
reg m;
always@(posedge clk) begin
    if(reset) begin
        m <= 0;
    end else if(stage == STAGE_MEASUREMENT_LOADING) begin
        m <= measurement;
    end
end

// Increase growth during the growth stage
assign neighbor_increase = odd && (stage == STAGE_GROW) && (last_stage != STAGE_GROW);

// root is the minimum of valid roots
// when root changes : change parent vector
wire [NEIGHBOR_COUNT-1 : 0] valid_from_root_comparotor;
wire [ADDRESS_WIDTH - 1 : 0] result_from_root_comparator;

min_val_less_8x_with_index #(
    .DATA_WIDTH(ADDRESS_WIDTH),
    .CHANNEL_COUNT(NEIGHBOR_COUNT)
) u_tree_compare_solver (
    .values(neighbor_root),
    .valids(neighbor_fully_grown),
    .result(result_from_root_comparotor),
    .output_valids(valid_from_root_comparotor)
);

always@(posedge clk) begin
    if(stage == STAGE_MEASUREMENT_LOADING) begin
        root <= ADDRESS;
        parent_vector <= 0;
    end else begin
        if (stage == STAGE_MERGE) begin
            if( (|valid_from_root_comparotor) && result_from_root_comparator < root) begin
                root <= result_from_root_comparator;
                parent_vector <= valid_from_root_comparotor;
            end
        end
    end
end

// Calculate the sub-tree parity and sub_tree touching boundary

wire next_cluster_parity = (^(neighbor_parent_vector & child_cluster_parity)) ^ m;
wire next_cluster_touching_boundary = (|(neighbor_parent_vector & child_touching_boundary)) | neighbor_is_boundary;

always@(posedge clk) begin
    if(stage == STAGE_MEASUREMENT_LOADING) begin
        cluster_parity <= measurement;
        cluster_touching_boundary <= 0;
    end else begin
        if (stage == STAGE_MERGE) begin
            cluster_parity <= next_cluster_parity;
            cluster_touching_boundary <= next_cluster_touching_boundary;
        end
    end
end

// Calculate cluster odd if you are the root.
// If not pass parents odd data
always@(posedge clk) begin
    if(stage == STAGE_MEASUREMENT_LOADING) begin
        odd <= measurement;
    end else begin
        if (stage == STAGE_MERGE) begin
            if(|parent_vector) begin
                odd <= |(parent_vector & parent_odd);
            end else begin
                odd <= next_cluster_parity | next_cluster_touching_boundary;
            end
        end
    end
end


// Calculate busy
always@(posedge clk) begin
    if(reset) begin
        busy <= 0;
    end else begin
        if (stage == STAGE_MERGE) begin
            if( ((|valid_from_root_comparotor) && result_from_root_comparator < root) ||
                 next_cluster_parity != cluster_parity ||
                 next_cluster_touching_boundary != cluster_touching_boundary ||
                 (|(parent_vector) & (parent_odd != odd)) ||
                 (~|(parent_vector) && ((next_cluster_parity | next_cluster_touching_boundary) != odd))
            )  begin
                busy <= 1;
            end else begin
                busy <= 0;
            end
        end
    end
end
            

endmodule