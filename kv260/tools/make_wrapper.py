"""Emit Vivado interface metadata for the hand-written GPU blocks."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
slave = [('AWADDR',8,'input'),('AWPROT',3,'input'),('AWVALID',1,'input'),('AWREADY',1,'output'),
         ('WDATA',32,'input'),('WSTRB',4,'input'),('WVALID',1,'input'),('WREADY',1,'output'),
         ('BRESP',2,'output'),('BVALID',1,'output'),('BREADY',1,'input'),
         ('ARADDR',8,'input'),('ARPROT',3,'input'),('ARVALID',1,'input'),('ARREADY',1,'output'),
         ('RDATA',32,'output'),('RRESP',2,'output'),('RVALID',1,'output'),('RREADY',1,'input')]
master = [('AWADDR',32,'output'),('AWLEN',8,'output'),('AWSIZE',3,'output'),('AWBURST',2,'output'),
          ('AWLOCK',1,'output'),('AWCACHE',4,'output'),('AWPROT',3,'output'),('AWVALID',1,'output'),('AWREADY',1,'input'),
          ('WDATA',32,'output'),('WSTRB',4,'output'),('WLAST',1,'output'),('WVALID',1,'output'),('WREADY',1,'input'),
          ('BRESP',2,'input'),('BVALID',1,'input'),('BREADY',1,'output'),
          ('ARADDR',32,'output'),('ARLEN',8,'output'),('ARSIZE',3,'output'),('ARBURST',2,'output'),
          ('ARLOCK',1,'output'),('ARCACHE',4,'output'),('ARPROT',3,'output'),('ARVALID',1,'output'),('ARREADY',1,'input'),
          ('RDATA',32,'input'),('RRESP',2,'input'),('RLAST',1,'input'),('RVALID',1,'input'),('RREADY',1,'output')]
lines=['`timescale 1ns/1ps','module KV260_GPU (',
       ' (* X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 clk CLK",',
       '    X_INTERFACE_PARAMETER="ASSOCIATED_BUSIF S_AXI:M_AXI, ASSOCIATED_RESET resetn" *) input wire clk,',
       ' (* X_INTERFACE_INFO="xilinx.com:signal:reset:1.0 resetn RST",',
       '    X_INTERFACE_PARAMETER="POLARITY ACTIVE_LOW" *) input wire resetn,']
ports=[]
for bus, signals in [('S_AXI',slave),('M_AXI',master)]:
    for signal,width,direction in signals:
        decl=f'{direction} wire ' + (f'[{width-1}:0] ' if width>1 else '')+bus.lower()+'_'+signal.lower()
        param=''
        if signal=='AWADDR':
            protocol='AXI4LITE' if bus=='S_AXI' else 'AXI4'
            param=f' (* X_INTERFACE_PARAMETER="PROTOCOL {protocol}, DATA_WIDTH 32, ADDR_WIDTH {width}" *)'
        ports.append(f' (* X_INTERFACE_INFO="xilinx.com:interface:aximm:1.0 {bus} {signal}" *){param} {decl}')
lines.append(',\n'.join(ports)); lines.append(');')
lines.append('''
 wire start,busy,done,target_buffer;
 wire [3:0] error_code;
 wire [31:0] region_base,matrix_offset,vertex_offset,vertex_count,near_q16;
 wire [31:0] accepted,written,skipped;
 wire rd_valid,rd_ready,rsp_valid,rsp_ready,rsp_error;
 wire wr_valid,wr_ready,wr_done,wr_error,write_idle;
 wire [31:0] rd_addr,rsp_data,wr_addr,wr_data;
 kv260_regs registers(.clk(clk),.resetn(resetn),
''')
reg_ports=[s.lower() for s,_,_ in slave if s not in ('AWPROT','ARPROT')]
lines.append(',\n'.join(f' .{p}(s_axi_{p})' for p in reg_ports)+',')
lines.append('''
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
''')
mem_ports=['araddr','arvalid','arready','rdata','rresp','rvalid','rlast','rready',
           'awaddr','awvalid','awready','wdata','wvalid','wready','bresp','bvalid','bready']
lines.append(',\n'.join(f' .{p}(m_axi_{p})' for p in mem_ports)+');')
lines.append('''
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
''')
(root/'rtl/KV260_GPU.v').write_text('\n'.join(lines),encoding='utf-8')
