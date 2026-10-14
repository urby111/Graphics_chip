`timescale 1ns / 1ps
// Fetch the matrix, then stream XYZ vertices from DDR.
module kv260_engine (
    input wire clk, resetn, start,
    input wire [31:0] region_base, matrix_offset, vertex_offset, vertex_count,
    input wire signed [31:0] near_q16,
    input wire target_buffer,

    output wire busy,
    output reg done,
    output reg [3:0] error_code,
    output reg [31:0] accepted, written, skipped,

    output wire rd_valid,
    input wire rd_ready,
    output wire [31:0] rd_addr,
    input wire rsp_valid,
    output wire rsp_ready,
    input wire [31:0] rsp_data,
    input wire rsp_error,

    output wire wr_valid,
    input wire wr_ready,
    output wire [31:0] wr_addr, wr_data,
    input wire wr_done, wr_error, write_idle
);
    localparam IDLE   = 0,
               M_REQ  = 1,
               M_RSP  = 2,
               M_SEND = 3,
               V_REQ  = 4,
               V_RSP  = 5,
               V_SEND = 6,
               DRAIN  = 7,
               FAULT  = 8;

    reg [3:0] state;
    reg [31:0] base, pointer, vertices_base, count;
    reg signed [31:0] active_near, matrix_word, vx, vy, vz;
    reg buffer;
    reg [3:0] matrix_index;
    reg [1:0] axis;
    reg [31:0] completed;

    wire m_ready, m_loaded, v_ready, m_valid, m_out_ready;
    wire signed [31:0] mx, my, mz, mw;
    wire [3:0] overflow;

    wire p_valid, p_ready, p_inside, p_rejected, p_buffer;
    wire signed [31:0] px, py, depth;
    wire [15:0] pw, ph;

    wire p_busy, w_busy, write_valid, drop, write_buffer;
    wire [31:0] write_offset, write_data;
    wire [3:0] write_strobe;

    wire faulted = state == FAULT;
    wire pipe_reset = !resetn || faulted;

    // Inputs must fit below the framebuffers without overlapping.
    wire [63:0] matrix_end = {32'b0, matrix_offset} + 64'd64;
    wire [63:0] vertex_end = {32'b0, vertex_offset} + ({32'b0, vertex_count} * 64'd12);
    wire configuration_ok = region_base[1:0] == 0 && matrix_offset[1:0] == 0 &&
        vertex_offset[1:0] == 0 && region_base >= 32'h00100000 && region_base <= 32'h7f700000 &&
        matrix_end <= 64'h100000 && vertex_end <= 64'h100000 &&
        (matrix_end <= {32'b0, vertex_offset} || vertex_end <= {32'b0, matrix_offset}) &&
        vertex_count <= 32'd16384 && near_q16 > 0;

    assign busy = state != IDLE;
    assign rd_valid = resetn && (state == M_REQ || state == V_REQ);
    assign rd_addr = pointer;
    assign rsp_ready = state == M_RSP || state == V_RSP || state == FAULT;

    assign wr_valid = write_valid && !faulted;
    assign wr_addr = base + write_offset;

    // Convert 00RRGGBB to the display's AABBGGRR format.
    assign wr_data = {8'hff, write_data[7:0], write_data[15:8], write_data[23:16]};

    Matrix_Vertex transform (
        .clk(clk),
        .rst(pipe_reset),

        .matrix_valid(state == M_SEND),
        .matrix_ready(m_ready),
        .matrix_data(matrix_word),
        .matrix_loaded(m_loaded),

        .vertex_valid(state == V_SEND),
        .vertex_ready(v_ready),
        .vertex_x(vx),
        .vertex_y(vy),
        .vertex_z(vz),

        .out_valid(m_valid),
        .out_ready(m_out_ready),
        .result_x(mx),
        .result_y(my),
        .result_z(mz),
        .result_w(mw),
        .out_overflow(overflow)
    );

    Screen_Position projection (
        .clk(clk),
        .rst(pipe_reset),
        .in_valid(m_valid),
        .in_ready(m_out_ready),
        .in_x(mx),
        .in_y(my),
        .in_z(mz),
        .in_w(mw),
        .in_overflow(overflow),

        .screen_width(16'd640),
        .screen_height(16'd480),
        .near_q16(active_near),
        .buffer_select(buffer),

        .out_valid(p_valid),
        .out_ready(p_ready),
        .x2d(px),
        .y2d(py),
        .out_depth(depth),
        .out_in_frame(p_inside),
        .out_rejected(p_rejected),
        .out_buffer_select(p_buffer),
        .out_width(pw),
        .out_height(ph),
        .busy(p_busy)
    );

    Framebuffer_Write writer (
        .clk(clk),
        .rst(pipe_reset),
        .in_valid(p_valid),
        .in_ready(p_ready),
        .x2d(px),
        .y2d(py),
        .in_frame(p_inside),
        .in_rejected(p_rejected),
        .buffer_select(p_buffer),

        .screen_width(pw),
        .screen_height(ph),
        .buffer_a_offset(32'h100000),
        .buffer_b_offset(32'h300000),
        .stride_bytes(32'd2560),
        .region_bytes(32'h800000),

        .wr_valid(write_valid),
        .wr_ready(wr_ready && !faulted),
        .wr_addr(write_offset),
        .wr_data(write_data),
        .wr_strb(write_strobe),
        .wr_buffer_select(write_buffer),
        .dropped(drop),
        .busy(w_busy)
    );

    always @(posedge clk) begin
        if (!resetn) begin
            state <= IDLE;
            done <= 0;
            error_code <= 0;
            accepted <= 0;
            written <= 0;
            skipped <= 0;
            completed <= 0;
            base <= 0;
            pointer <= 0;
            vertices_base <= 0;
            count <= 0;
            active_near <= 65536;
            matrix_word <= 0;
            vx <= 0;
            vy <= 0;
            vz <= 0;
            buffer <= 0;
            matrix_index <= 0;
            axis <= 0;
        end else begin
            done <= 0;

            // Count each vertex once it is written or dropped.
            if (!faulted) begin
                if (wr_valid && wr_ready) written <= written + 1;
                if (drop) skipped <= skipped + 1;

                case ({wr_valid && wr_ready, drop})
                    2'b11: completed <= completed + 2;
                    2'b01, 2'b10: completed <= completed + 1;
                    default: begin end
                endcase
            end

            case (state)
                IDLE: if (start) begin
                    error_code <= 0;
                    accepted <= 0;
                    written <= 0;
                    skipped <= 0;
                    completed <= 0;

                    if (!configuration_ok) begin
                        error_code <= 1;
                        done <= 1;
                    end else begin
                        base <= region_base;
                        pointer <= region_base + matrix_offset;
                        vertices_base <= region_base + vertex_offset;
                        count <= vertex_count;
                        active_near <= near_q16;
                        buffer <= target_buffer;
                        matrix_index <= 0;
                        state <= M_REQ;
                    end
                end

                // Load all 16 matrix words before fetching vertices.
                M_REQ: if (rd_ready) state <= M_RSP;

                M_RSP: if (rsp_valid) begin
                    matrix_word <= rsp_data;
                    state <= M_SEND;
                end

                M_SEND: if (m_ready) begin
                    if (matrix_index == 15) begin
                        pointer <= vertices_base;
                        axis <= 0;
                        state <= count == 0 ? DRAIN : V_REQ;
                    end else begin
                        matrix_index <= matrix_index + 1;
                        pointer <= pointer + 4;
                        state <= M_REQ;
                    end
                end

                // Assemble one XYZ vertex from three DDR words.
                V_REQ: if (rd_ready) state <= V_RSP;

                V_RSP: if (rsp_valid) begin
                    case (axis)
                        0: vx <= rsp_data;
                        1: vy <= rsp_data;
                        2: vz <= rsp_data;
                        default: begin end
                    endcase

                    pointer <= pointer + 4;

                    if (axis == 2) state <= V_SEND;
                    else begin
                        axis <= axis + 1;
                        state <= V_REQ;
                    end
                end

                V_SEND: if (v_ready && m_loaded) begin
                    accepted <= accepted + 1;
                    axis <= 0;
                    state <= accepted + 1 == count ? DRAIN : V_REQ;
                end

                // Wait for the pipeline and final write response.
                DRAIN: if (completed == count && write_idle && !p_busy && !w_busy && !m_valid) begin
                    state <= IDLE;
                    done <= 1;
                end

                // Finish outstanding AXI transactions before leaving FAULT.
                FAULT: if ((!rd_valid && rd_ready) && write_idle) begin
                    state <= IDLE;
                    done <= 1;
                end

                default: state <= IDLE;
            endcase

            if (busy && !faulted && ((rsp_valid && rsp_ready && rsp_error) || wr_error)) begin
                error_code <= wr_error ? 4'd3 : 4'd2;
                state <= FAULT;
            end
        end
    end
endmodule
