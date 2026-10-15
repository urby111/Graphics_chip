`timescale 1ns / 1ps
// AXI-Lite control registers; responses stay valid until accepted.
module kv260_regs (
    // Rising-edge clock; resetn resets the module when low.
    input wire clk, resetn,

    // CPU write address and data arrive independently.
    input wire [7:0] awaddr,
    input wire awvalid,
    output wire awready,
    input wire [31:0] wdata,
    input wire [3:0] wstrb, // One enable per byte of wdata.
    input wire wvalid,
    output wire wready,
    output reg [1:0] bresp, // 00 = accepted; 10 = rejected.
    output reg bvalid,
    input wire bready,

    // CPU reads a register by its byte offset.
    input wire [7:0] araddr,
    input wire arvalid,
    output wire arready,
    output reg [31:0] rdata,
    output reg [1:0] rresp, // 00 = valid register; 10 = bad address.
    output reg rvalid,
    input wire rready,

    // Stored job settings drive the engine through shared wires.
    output reg start, // One-clock pulse: DDR inputs are ready to use.
    // Matrix/vertex locations are byte offsets from region_base.
    output reg [31:0] region_base, matrix_offset, vertex_offset, vertex_count,
    output reg signed [31:0] near_q16, // Q16.16 near-plane distance.
    output reg target_buffer, // 0 = framebuffer A; 1 = B.

    // Engine status and counters returned to the CPU on reads.
    input wire busy, done,
    input wire [3:0] error_code,
    input wire [31:0] accepted, written, skipped
);
    // Hold one write until both its address and data have arrived.
    reg aw_pending, w_pending;
    reg [7:0] saved_aw;
    reg [31:0] saved_w;
    reg [3:0] saved_strb;
    reg done_latched; // Remember DONE until reset or the next START.

    // Accept requests only when their holding slots are free.
    assign awready = resetn && !aw_pending && !bvalid;
    assign wready = resetn && !w_pending && !bvalid;
    assign arready = resetn && !rvalid;

    // Update only the bytes selected by WSTRB.
    function [31:0] merge;
        input [31:0] old_word, new_word;
        input [3:0] strobes;
        integer i;
        begin
            merge = old_word;
            for (i = 0; i < 4; i = i + 1)
                if (strobes[i]) merge[i*8 +: 8] = new_word[i*8 +: 8];
        end
    endfunction

    always @(posedge clk) begin
        if (!resetn) begin
            // Clear transactions and restore the initial job settings.
            aw_pending <= 0;
            w_pending <= 0;
            saved_aw <= 0;
            saved_w <= 0;
            saved_strb <= 0;
            bvalid <= 0;
            bresp <= 0;
            rvalid <= 0;
            rdata <= 0;
            rresp <= 0;
            start <= 0;
            region_base <= 32'h10000000;
            matrix_offset <= 0;
            vertex_offset <= 64;
            vertex_count <= 0;
            near_q16 <= 65536;
            target_buffer <= 1;
            done_latched <= 0;
        end else begin
            // The START command below overrides this for one clock.
            start <= 0;

            // Capture completion; release responses after CPU acceptance.
            if (done) done_latched <= 1;
            if (bvalid && bready) bvalid <= 0;
            if (rvalid && rready) rvalid <= 0;

            // Write address and data may arrive on different cycles.
            if (awvalid && awready) begin
                saved_aw <= awaddr;
                aw_pending <= 1;
            end

            if (wvalid && wready) begin
                saved_w <= wdata;
                saved_strb <= wstrb;
                w_pending <= 1;
            end

            // Process the saved write once both halves are available.
            if (aw_pending && w_pending && !bvalid) begin
                aw_pending <= 0;
                w_pending <= 0;
                bvalid <= 1;
                bresp <= 0;

                // Protect the active job and require four-byte alignment.
                if (busy || start || saved_aw[1:0] != 0) bresp <= 2'b10;
                else case (saved_aw)
                    8'h00: begin
                        // Writing bit 0 starts a job and clears old DONE.
                        if (saved_strb[0] && saved_w[0]) begin
                            start <= 1;
                            done_latched <= 0;
                        end
                    end

                    8'h10: region_base <= merge(region_base, saved_w, saved_strb); // DDR region start.
                    8'h14: matrix_offset <= merge(matrix_offset, saved_w, saved_strb); // First matrix word.
                    8'h18: vertex_offset <= merge(vertex_offset, saved_w, saved_strb); // First vertex.
                    8'h1c: vertex_count <= merge(vertex_count, saved_w, saved_strb); // Vertices to process.
                    8'h20: near_q16 <= merge(near_q16, saved_w, saved_strb); // Clipping distance.
                    8'h24: if (saved_strb[0]) target_buffer <= saved_w[0]; // Destination A/B.
                    default: bresp <= 2'b10;
                endcase
            end

            // Snapshot the selected value; hold it until rready is high.
            if (arvalid && arready) begin
                rvalid <= 1;
                rresp <= 0;
                rdata <= 0;

                if (araddr[1:0] != 0) rresp <= 2'b10;
                else case (araddr)
                    8'h00: rdata <= 0; // START is a command, not a stored flag.
                    // [7:4] error code, [3] error, [1] DONE, [0] busy/START.
                    8'h04: rdata <= {24'b0, error_code, (|error_code), 1'b0, done_latched, (busy || start)};
                    8'h08: rdata <= 32'h4b563031; // KV01

                    // Read back the stored job settings.
                    8'h10: rdata <= region_base;
                    8'h14: rdata <= matrix_offset;
                    8'h18: rdata <= vertex_offset;
                    8'h1c: rdata <= vertex_count;
                    8'h20: rdata <= near_q16;
                    8'h24: rdata <= {31'b0, target_buffer};

                    // Counters are maintained by the engine.
                    8'h28: rdata <= accepted; // Vertices submitted to the pipeline.
                    8'h2c: rdata <= written; // Pixel writes handed to memory.
                    8'h30: rdata <= skipped; // Rejected or off-screen points.
                    default: rresp <= 2'b10;
                endcase
            end
        end
    end
endmodule
