`timescale 1ns/1ps
module KV260_GPU (
 (* X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 clk CLK",
    X_INTERFACE_PARAMETER="ASSOCIATED_BUSIF S_AXI:M_AXI, ASSOCIATED_RESET resetn" *) input wire clk,
 (* X_INTERFACE_INFO="xilinx.com:signal:reset:1.0 resetn RST",
    X_INTERFACE_PARAMETER="POLARITY ACTIVE_LOW" *) input wire resetn,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *) (* X_INTERFACE_PARAMETER="PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 8" *) input wire [7:0] s_axi_awaddr,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWPROT" *) input wire [2:0] s_axi_awprot,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *) input wire s_axi_awvalid,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *) output wire s_axi_awready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WDATA" *) input wire [31:0] s_axi_wdata,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *) input wire [3:0] s_axi_wstrb,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WVALID" *) input wire s_axi_wvalid,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI WREADY" *) output wire s_axi_wready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BRESP" *) output wire [1:0] s_axi_bresp,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BVALID" *) output wire s_axi_bvalid,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI BREADY" *) input wire s_axi_bready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *) input wire [7:0] s_axi_araddr,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARPROT" *) input wire [2:0] s_axi_arprot,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *) input wire s_axi_arvalid,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *) output wire s_axi_arready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RDATA" *) output wire [31:0] s_axi_rdata,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RRESP" *) output wire [1:0] s_axi_rresp,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RVALID" *) output wire s_axi_rvalid,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 S_AXI RREADY" *) input wire s_axi_rready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI AWADDR" *) (* X_INTERFACE_PARAMETER="PROTOCOL AXI4, DATA_WIDTH 32, ADDR_WIDTH 32" *) output wire [31:0] m_axi_awaddr,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI AWLEN" *) output wire [7:0] m_axi_awlen,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI AWSIZE" *) output wire [2:0] m_axi_awsize,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI AWBURST" *) output wire [1:0] m_axi_awburst,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI AWLOCK" *) output wire m_axi_awlock,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI AWCACHE" *) output wire [3:0] m_axi_awcache,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI AWPROT" *) output wire [2:0] m_axi_awprot,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI AWVALID" *) output wire m_axi_awvalid,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI AWREADY" *) input wire m_axi_awready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI WDATA" *) output wire [31:0] m_axi_wdata,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI WSTRB" *) output wire [3:0] m_axi_wstrb,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI WLAST" *) output wire m_axi_wlast,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI WVALID" *) output wire m_axi_wvalid,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI WREADY" *) input wire m_axi_wready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI BRESP" *) input wire [1:0] m_axi_bresp,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI BVALID" *) input wire m_axi_bvalid,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI BREADY" *) output wire m_axi_bready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARADDR" *) output wire [31:0] m_axi_araddr,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARLEN" *) output wire [7:0] m_axi_arlen,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARSIZE" *) output wire [2:0] m_axi_arsize,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARBURST" *) output wire [1:0] m_axi_arburst,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARLOCK" *) output wire m_axi_arlock,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARCACHE" *) output wire [3:0] m_axi_arcache,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARPROT" *) output wire [2:0] m_axi_arprot,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARVALID" *) output wire m_axi_arvalid,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI ARREADY" *) input wire m_axi_arready,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI RDATA" *) input wire [31:0] m_axi_rdata,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI RRESP" *) input wire [1:0] m_axi_rresp,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI RLAST" *) input wire m_axi_rlast,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI RVALID" *) input wire m_axi_rvalid,
 (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 M_AXI RREADY" *) output wire m_axi_rready
);

 wire start,busy,done,target_buffer;
 wire [3:0] error_code;
 wire [31:0] region_base,matrix_offset,vertex_offset,vertex_count,near_q16;
 wire [31:0] accepted,written,skipped;
 wire rd_valid,rd_ready,rsp_valid,rsp_ready,rsp_error;
 wire wr_valid,wr_ready,wr_done,wr_error,write_idle;
 wire [31:0] rd_addr,rsp_data,wr_addr,wr_data;
 kv260_regs registers(.clk(clk),.resetn(resetn),

 .awaddr(s_axi_awaddr),
 .awvalid(s_axi_awvalid),
 .awready(s_axi_awready),
 .wdata(s_axi_wdata),
 .wstrb(s_axi_wstrb),
 .wvalid(s_axi_wvalid),
 .wready(s_axi_wready),
 .bresp(s_axi_bresp),
 .bvalid(s_axi_bvalid),
 .bready(s_axi_bready),
 .araddr(s_axi_araddr),
 .arvalid(s_axi_arvalid),
 .arready(s_axi_arready),
 .rdata(s_axi_rdata),
 .rresp(s_axi_rresp),
 .rvalid(s_axi_rvalid),
 .rready(s_axi_rready),

 .start(start),.busy(busy),.done(done),.error_code(error_code),
 .region_base(region_base),.matrix_offset(matrix_offset),.vertex_offset(vertex_offset),
 .vertex_count(vertex_count),.near_q16(near_q16),.target_buffer(target_buffer),
 .accepted(accepted),.written(written),.skipped(skipped));
 kv260_engine engine(.clk(clk),.resetn(resetn),.start(start),.busy(busy),.done(done),
 .error_code(error_code),.region_base(region_base),.matrix_offset(matrix_offset),
 .vertex_offset(vertex_offset),.vertex_count(vertex_count),.near_q16(near_q16),
 .target_buffer(target_buffer),.accepted(accepted),.written(written),.skipped(skipped),
 .rd_valid(rd_valid),.rd_ready(rd_ready),.rd_addr(rd_addr),
 .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_data(rsp_data),.rsp_error(rsp_error),
 .wr_valid(wr_valid),.wr_ready(wr_ready),.wr_addr(wr_addr),.wr_data(wr_data),
 .wr_done(wr_done),.wr_error(wr_error),.write_idle(write_idle));
 kv260_memory memory(.clk(clk),.resetn(resetn),
 .rd_valid(rd_valid),.rd_ready(rd_ready),.rd_addr(rd_addr),
 .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_data(rsp_data),.rsp_error(rsp_error),
 .wr_valid(wr_valid),.wr_ready(wr_ready),.wr_addr(wr_addr),.wr_data(wr_data),
 .wr_done(wr_done),.wr_error(wr_error),.write_idle(write_idle),

 .araddr(m_axi_araddr),
 .arvalid(m_axi_arvalid),
 .arready(m_axi_arready),
 .rdata(m_axi_rdata),
 .rresp(m_axi_rresp),
 .rvalid(m_axi_rvalid),
 .rlast(m_axi_rlast),
 .rready(m_axi_rready),
 .awaddr(m_axi_awaddr),
 .awvalid(m_axi_awvalid),
 .awready(m_axi_awready),
 .wdata(m_axi_wdata),
 .wvalid(m_axi_wvalid),
 .wready(m_axi_wready),
 .bresp(m_axi_bresp),
 .bvalid(m_axi_bvalid),
 .bready(m_axi_bready));

 assign m_axi_arlen=0; assign m_axi_awlen=0;
 assign m_axi_arsize=3'd2; assign m_axi_awsize=3'd2;
 assign m_axi_arburst=2'b01; assign m_axi_awburst=2'b01;
 assign m_axi_arlock=0; assign m_axi_awlock=0;
 assign m_axi_arcache=4'b0011; assign m_axi_awcache=4'b0011;
 assign m_axi_arprot=0; assign m_axi_awprot=0;
 assign m_axi_wstrb=4'hf; assign m_axi_wlast=1;
 // PROT is unused on this private control aperture.
 wire unused_prot = ^{s_axi_arprot,s_axi_awprot};
endmodule
