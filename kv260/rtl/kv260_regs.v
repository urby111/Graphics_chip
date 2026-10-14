`timescale 1ns/1ps
// AXI-Lite: independent AW/W capture; hold B/R until accepted.
module kv260_regs (
 input wire clk, resetn,
 input wire [7:0] awaddr, input wire awvalid, output wire awready,
 input wire [31:0] wdata, input wire [3:0] wstrb,
 input wire wvalid, output wire wready,
 output reg [1:0] bresp, output reg bvalid, input wire bready,
 input wire [7:0] araddr, input wire arvalid, output wire arready,
 output reg [31:0] rdata, output reg [1:0] rresp,
 output reg rvalid, input wire rready,
 output reg start,
 output reg [31:0] region_base, matrix_offset, vertex_offset, vertex_count,
 output reg signed [31:0] near_q16, output reg target_buffer,
 input wire busy, done, input wire [3:0] error_code,
 input wire [31:0] accepted, written, skipped
);
 reg aw_pending, w_pending;
 reg [7:0] saved_aw;
 reg [31:0] saved_w;
 reg [3:0] saved_strb;
 reg done_latched;
 assign awready = resetn && !aw_pending && !bvalid;
 assign wready = resetn && !w_pending && !bvalid;
 assign arready = resetn && !rvalid;
 function [31:0] merge;
  input [31:0] old_word, new_word; input [3:0] strobes;
  integer i;
  begin
   merge = old_word;
   for (i=0;i<4;i=i+1) if (strobes[i]) merge[i*8+:8]=new_word[i*8+:8];
  end
 endfunction
 always @(posedge clk) begin
  if (!resetn) begin
   aw_pending<=0; w_pending<=0; saved_aw<=0; saved_w<=0; saved_strb<=0;
   bvalid<=0; bresp<=0; rvalid<=0; rdata<=0; rresp<=0; start<=0;
   region_base<=32'h10000000; matrix_offset<=0; vertex_offset<=64;
   vertex_count<=0; near_q16<=65536; target_buffer<=1; done_latched<=0;
  end else begin
   start<=0;
   if (done) done_latched<=1;
   if (bvalid && bready) bvalid<=0;
   if (rvalid && rready) rvalid<=0;
   if (awvalid && awready) begin saved_aw<=awaddr; aw_pending<=1; end
   if (wvalid && wready) begin saved_w<=wdata; saved_strb<=wstrb; w_pending<=1; end
   if (aw_pending && w_pending && !bvalid) begin
    aw_pending<=0; w_pending<=0; bvalid<=1; bresp<=0;
    // start remains high until the engine has sampled it on the next edge.
    if (busy || start || saved_aw[1:0]!=0) bresp<=2'b10;
    else case (saved_aw)
     8'h00: begin
      if (saved_strb[0] && saved_w[0]) begin start<=1; done_latched<=0; end
     end
     8'h10: region_base<=merge(region_base,saved_w,saved_strb);
     8'h14: matrix_offset<=merge(matrix_offset,saved_w,saved_strb);
     8'h18: vertex_offset<=merge(vertex_offset,saved_w,saved_strb);
     8'h1c: vertex_count<=merge(vertex_count,saved_w,saved_strb);
     8'h20: near_q16<=merge(near_q16,saved_w,saved_strb);
     8'h24: if (saved_strb[0]) target_buffer<=saved_w[0];
     default: bresp<=2'b10;
    endcase
   end
   if (arvalid && arready) begin
    rvalid<=1; rresp<=0; rdata<=0;
    if (araddr[1:0]!=0) rresp<=2'b10;
    else case (araddr)
     8'h00: rdata<=0;
     8'h04: rdata<={24'b0,error_code,(|error_code),1'b0,done_latched,(busy||start)};
     8'h08: rdata<=32'h4b563031; // KV01
     8'h10: rdata<=region_base;
     8'h14: rdata<=matrix_offset;
     8'h18: rdata<=vertex_offset;
     8'h1c: rdata<=vertex_count;
     8'h20: rdata<=near_q16;
     8'h24: rdata<={31'b0,target_buffer};
     8'h28: rdata<=accepted;
     8'h2c: rdata<=written;
     8'h30: rdata<=skipped;
     default: rresp<=2'b10;
    endcase
   end
  end
 end
endmodule
