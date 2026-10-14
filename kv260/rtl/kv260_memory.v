`timescale 1ns / 1ps
// One read and one write may be outstanding at a time.
module kv260_memory (
    input wire clk, resetn,

    input wire rd_valid,
    output wire rd_ready,
    input wire [31:0] rd_addr,
    output wire rsp_valid,
    input wire rsp_ready,
    output wire [31:0] rsp_data,
    output wire rsp_error,

    input wire wr_valid,
    output wire wr_ready,
    input wire [31:0] wr_addr, wr_data,
    output wire wr_done, wr_error, write_idle,

    output reg [31:0] araddr,
    output wire arvalid,
    input wire arready,
    input wire [31:0] rdata,
    input wire [1:0] rresp,
    input wire rvalid, rlast,
    output wire rready,

    output reg [31:0] awaddr,
    output wire awvalid,
    input wire awready,
    output reg [31:0] wdata,
    output wire wvalid,
    input wire wready,
    input wire [1:0] bresp,
    input wire bvalid,
    output wire bready
);
    localparam R_IDLE = 0,
               R_ADDR = 1,
               R_DATA = 2;

    reg [1:0] read_state;
    reg writing, aw_pending, w_pending;

    assign rd_ready = resetn && read_state == R_IDLE;
    assign arvalid = resetn && read_state == R_ADDR;
    assign rsp_valid = resetn && read_state == R_DATA && rvalid;
    assign rsp_data = rdata;
    assign rsp_error = (rresp != 0) || !rlast;
    assign rready = resetn && read_state == R_DATA && rsp_ready;

    assign write_idle = !writing;
    assign wr_ready = resetn && !writing;
    assign awvalid = resetn && aw_pending;
    assign wvalid = resetn && w_pending;
    assign bready = resetn && writing && !aw_pending && !w_pending;
    assign wr_done = bvalid && bready;
    assign wr_error = wr_done && bresp != 0;

    always @(posedge clk) begin
        if (!resetn) begin
            read_state <= R_IDLE;
            araddr <= 0;
            awaddr <= 0;
            wdata <= 0;
            writing <= 0;
            aw_pending <= 0;
            w_pending <= 0;
        end else begin
            case (read_state)
                R_IDLE: if (rd_valid) begin
                    araddr <= rd_addr;
                    read_state <= R_ADDR;
                end

                R_ADDR: if (arready) read_state <= R_DATA;
                R_DATA: if (rvalid && rready) read_state <= R_IDLE;
                default: read_state <= R_IDLE;
            endcase

            // Hold address and data independently until each is accepted.
            if (wr_valid && wr_ready) begin
                writing <= 1;
                aw_pending <= 1;
                w_pending <= 1;
                awaddr <= wr_addr;
                wdata <= wr_data;
            end

            if (awvalid && awready) aw_pending <= 0;
            if (wvalid && wready) w_pending <= 0;

            // A write completes only after its B response.
            if (wr_done) writing <= 0;
        end
    end
endmodule
