/* Copyright (c) 2026 MiSTfits contributors. zlib License; see LICENSE. */
`timescale 1ns/1ps
module mistfits_hps #(
  parameter CONF_STR = 0, parameter integer CONF_STR_BRAM=0,
  parameter integer PS2DIV=0, WIDE=0, VDNUM=1, BLKSZ=2, PS2WE=0,
  parameter integer STRLEN=$bits(CONF_STR)/8, F12KEYMOD=0
)(
  input wire clk_sys, inout wire [48:0] HPS_BUS,
  output reg [31:0] joystick_0=0,joystick_1=0,joystick_2=0,joystick_3=0,joystick_4=0,joystick_5=0,
  output reg [15:0] joystick_l_analog_0=0,joystick_l_analog_1=0,joystick_l_analog_2=0,joystick_l_analog_3=0,joystick_l_analog_4=0,joystick_l_analog_5=0,
  output reg [15:0] joystick_r_analog_0=0,joystick_r_analog_1=0,joystick_r_analog_2=0,joystick_r_analog_3=0,joystick_r_analog_4=0,joystick_r_analog_5=0,
  input wire [15:0] joystick_0_rumble,joystick_1_rumble,joystick_2_rumble,joystick_3_rumble,joystick_4_rumble,joystick_5_rumble,
  output reg [7:0] paddle_0=0,paddle_1=0,paddle_2=0,paddle_3=0,paddle_4=0,paddle_5=0,
  output reg [8:0] spinner_0=0,spinner_1=0,spinner_2=0,spinner_3=0,spinner_4=0,spinner_5=0,
  output wire ps2_kbd_clk_out,ps2_kbd_data_out,input wire ps2_kbd_clk_in,ps2_kbd_data_in,
  output wire ps2_mouse_clk_out,ps2_mouse_data_out,input wire ps2_mouse_clk_in,ps2_mouse_data_in,
  input wire [2:0] ps2_kbd_led_status,ps2_kbd_led_use,
  output reg [10:0] ps2_key=0, output reg [24:0] ps2_mouse=0, output reg [15:0] ps2_mouse_ext=0,
  output wire [1:0] buttons, output wire forced_scandoubler,direct_video,input wire video_rotated,new_vmode,
  inout wire [21:0] gamma_bus, output reg [127:0] status=0,input wire [127:0] status_in,input wire status_set,input wire [15:0] status_menumask,
  input wire info_req,input wire [7:0] info,
  output reg [VDNUM-1:0] img_mounted=0,output reg img_readonly=0,output reg [63:0] img_size=0,
  input wire [31:0] sd_lba[VDNUM],input wire [5:0] sd_blk_cnt[VDNUM],input wire [VDNUM-1:0] sd_rd,sd_wr,output reg [VDNUM-1:0] sd_ack=0,
  output reg [(WIDE?13:14)-1:0] sd_buff_addr=0,output reg [(WIDE?16:8)-1:0] sd_buff_dout=0,input wire [(WIDE?16:8)-1:0] sd_buff_din[VDNUM],output reg sd_buff_wr=0,
  output reg ioctl_download=0,output reg [15:0] ioctl_index=0,output reg ioctl_wr=0,output reg [26:0] ioctl_addr=0,output reg [(WIDE?16:8)-1:0] ioctl_dout=0,
  output reg ioctl_upload=0,output reg ioctl_rd=0,output reg [31:0] ioctl_file_ext=0,input wire ioctl_upload_req,input wire [7:0] ioctl_upload_index,input wire [(WIDE?16:8)-1:0] ioctl_din,input wire ioctl_wait,
  output reg [15:0] sdram_sz=0,output reg [64:0] RTC=0,output reg [32:0] TIMESTAMP=0,output reg [7:0] uart_mode=0,output reg [31:0] uart_speed=0,
  inout wire [35:0] EXT_BUS
);
  localparam DW=(WIDE?16:8), AW=(WIDE?13:14);
  localparam CONF_MEM_SIZE=(STRLEN>0)?STRLEN:1;
  reg [7:0] conf_mem[0:CONF_MEM_SIZE-1];integer conf_i;
  initial if(CONF_STR_BRAM!=0&&STRLEN>0) begin
    if($bits(CONF_STR)<8*STRLEN)$readmemh("cfgstr.hex",conf_mem,0,STRLEN-1);
    else for(conf_i=0;conf_i<STRLEN;conf_i=conf_i+1) conf_mem[conf_i]=CONF_STR[(STRLEN-1-conf_i)*8 +:8];
  end
  wire [15:0] din=HPS_BUS[31:16]; wire stb=HPS_BUS[33], io=HPS_BUS[34], fi=HPS_BUS[35];
  reg [15:0] io_resp=0,fi_resp=0,cmd=0; reg [4:0] pos=0; reg old_io=0,old_fi=0;
  reg [15:0] config_reg=0; assign buttons=config_reg[1:0]; assign forced_scandoubler=config_reg[4]; assign direct_video=config_reg[10];
  assign HPS_BUS[15:0]=EXT_BUS[32]?16'bz:(fi?fi_resp:io_resp); assign HPS_BUS[32]=WIDE!=0; assign HPS_BUS[36]=clk_sys; assign HPS_BUS[37]=ioctl_wait;
  assign EXT_BUS[15:0]=EXT_BUS[32]?16'bz:(fi?fi_resp:io_resp); assign EXT_BUS[31:16]=HPS_BUS[31:16]; assign EXT_BUS[33]=stb; assign EXT_BUS[35]=fi;
  reg gamma_en=0,gamma_wr=0; reg [9:0] gamma_addr=0; reg [7:0] gamma_val=0;
  assign gamma_bus[20:0]={clk_sys,gamma_en,gamma_wr,gamma_addr,gamma_val};
  reg kbd_put=0,mouse_put=0; reg [7:0] kbd_put_data=0,mouse_put_data=0; reg kbd_take=0,mouse_take=0;
  wire [7:0] kbd_rx_data,mouse_rx_data; wire kbd_rx_available,mouse_rx_available;
  generate if(PS2DIV==0) begin: no_serial
    assign ps2_kbd_clk_out=0;assign ps2_kbd_data_out=0;assign ps2_mouse_clk_out=0;assign ps2_mouse_data_out=0;
    assign kbd_rx_data=0;assign mouse_rx_data=0;assign kbd_rx_available=0;assign mouse_rx_available=0;
  end else begin: serial
    mistfits_ps2_engine #(.DIV(PS2DIV),.RECEIVE_ENABLE(PS2WE)) kbd_engine(clk_sys,kbd_put,kbd_put_data,kbd_take,kbd_rx_available,kbd_rx_data,ps2_kbd_clk_in,ps2_kbd_data_in,ps2_kbd_clk_out,ps2_kbd_data_out);
    mistfits_ps2_engine #(.DIV(PS2DIV),.RECEIVE_ENABLE(PS2WE)) mouse_engine(clk_sys,mouse_put,mouse_put_data,mouse_take,mouse_rx_available,mouse_rx_data,ps2_mouse_clk_in,ps2_mouse_data_in,ps2_mouse_clk_out,ps2_mouse_data_out);
  end endgenerate
  reg status_set_d=0,info_req_d=0,upload_req_d=0; reg [127:0] injected=0; reg [3:0] generation=0; reg [7:0] pending_info=0; reg upload_pending=0;
  reg discard=0; reg [7:0] keyhist[0:3]; reg [7:0] mouse_b0=0,mouse_b1=0,mouse_b2=0; reg [15:0] mouse_ext_work=0;
  reg [3:0] rr=0,selected_drive=0; integer k,off,chosen; reg found; reg [15:0] uart_mode_work=0; reg upload_first=0;

  reg [31:0] active_width=0,active_height=0,active_line_vid=0;
  reg [31:0] hs_period=0,vs_period=0,active_line_100=0,hdmi_vs_period=0;
  reg [7:0] pixel_spacing=0,de_start_v=0,mode_generation=0; reg [15:0] de_start_h=0;reg interlace=0;
  reg [31:0] width_work=0,height_work=0,line_vid_work=0;reg [15:0] hpos=0;reg [7:0] vpos=0,spacing_work=1;
  reg vid_vs_d=0,vid_hs_d=0,vid_de_d=0;reg [1:0] fields=0;reg measuring=0,first_line=0;reg [3:0] stable_count=0;reg mode_level=0;
  wire clk_vid=HPS_BUS[42],clk_100=HPS_BUS[43];
  always @(posedge clk_vid) begin
    vid_vs_d<=HPS_BUS[38];vid_hs_d<=HPS_BUS[39];vid_de_d<=HPS_BUS[40];
    if(HPS_BUS[41]) begin
      spacing_work<=1;
      if(measuring&&HPS_BUS[40]&&first_line) width_work<=width_work+1;
      if(measuring&&!vid_de_d&&HPS_BUS[40]) begin height_work<=height_work+1;if(first_line)begin de_start_h<=hpos;de_start_v<=vpos;end end
      if(measuring&&vid_de_d&&!HPS_BUS[40]&&first_line) begin pixel_spacing<=spacing_work;first_line<=0; end
      if(vid_hs_d&&!HPS_BUS[39]) vpos<=vpos+1;
      if(vid_vs_d&&!HPS_BUS[38]) begin
        fields<={fields[0],HPS_BUS[45]};interlace<=fields[0]|HPS_BUS[45];
        if(!HPS_BUS[45]) begin
          if(width_work!=0&&height_work!=0) begin
            active_width<=width_work;active_height<=height_work;active_line_vid<=line_vid_work;
            if(width_work!=active_width||height_work!=active_height||new_vmode!=mode_level) stable_count<=1;
            else if(stable_count==15) begin stable_count<=0;mode_generation<=mode_generation+1'b1;end else if(stable_count!=0)stable_count<=stable_count+1'b1;
            mode_level<=new_vmode;
          end
          width_work<=0;height_work<=0;line_vid_work<=0;vpos<=0;measuring<=1;first_line<=1;
        end
      end
    end else spacing_work<=spacing_work+1'b1;
    if(vid_hs_d&&!HPS_BUS[39])hpos<=1;else hpos<=hpos+1'b1;
    if(measuring&&HPS_BUS[40]&&first_line)line_vid_work<=line_vid_work+1;
  end

  reg s100_hs1=0,s100_hs2=0,s100_vs1=0,s100_vs2=0,s100_de1=0,s100_de2=0,s100_hd1=0,s100_hd2=0;
  reg [31:0] hc=0,vc=0,hdc=0,line100work=0;reg measuring100=0;
  always @(posedge clk_100) begin
    s100_hs1<=HPS_BUS[39];s100_hs2<=s100_hs1;s100_vs1<=HPS_BUS[38];s100_vs2<=s100_vs1;s100_de1<=HPS_BUS[40];s100_de2<=s100_de1;s100_hd1<=HPS_BUS[44];s100_hd2<=s100_hd1;
    hc<=hc+1;vc<=vc+1;hdc<=hdc+1;
    if(!s100_hs2&&s100_hs1)begin hs_period<=hc;hc<=0;end
    if(!s100_vs2&&s100_vs1)begin vs_period<=vc;vc<=0;active_line_100<=line100work;end
    if(!s100_hd2&&s100_hd1)begin hdmi_vs_period<=hdc;hdc<=0;end
    if(s100_vs2&&!s100_vs1)begin measuring100<=1;line100work<=0;end
    if(measuring100&&s100_de1)line100work<=line100work+1;
    if(measuring100&&s100_de2&&!s100_de1)measuring100<=0;
  end

  function [15:0] rumble(input [3:0] n); begin case(n) 0:rumble=joystick_0_rumble;1:rumble=joystick_1_rumble;2:rumble=joystick_2_rumble;3:rumble=joystick_3_rumble;4:rumble=joystick_4_rumble;5:rumble=joystick_5_rumble;default:rumble=0;endcase end endfunction
  function [31:0] lba(input integer n); begin lba=sd_lba[n]; end endfunction
  function [5:0] bcnt(input integer n); begin bcnt=sd_blk_cnt[n]; end endfunction

  always @(posedge clk_sys) begin
    old_io<=io; old_fi<=fi; status_set_d<=status_set; info_req_d<=info_req; upload_req_d<=ioctl_upload_req;
    gamma_wr<=0; sd_buff_wr<=0; ioctl_wr<=0; ioctl_rd<=0;kbd_put<=0;mouse_put<=0;kbd_take<=0;mouse_take<=0;
    if(status_set&&!status_set_d) begin injected<=status_in; generation<=generation+1'b1; end
    if(info_req&&!info_req_d) pending_info<=info;
    if(ioctl_upload_req&&!upload_req_d) upload_pending<=1;
    if(old_io&&!io) begin
      io_resp<=0; pos<=0; sd_ack<=0; img_mounted<=0;
      if(cmd[7:0]==8'h04&&!discard) begin ps2_mouse<={~ps2_mouse[24],mouse_b2,mouse_b1,mouse_b0}; ps2_mouse_ext<=mouse_ext_work; end
      if(cmd[7:0]==8'h05&&!discard) begin
        ps2_key[10]<=~ps2_key[10]; ps2_key[7:0]<=keyhist[0]; ps2_key[9]<=keyhist[1]!=8'hf0;
        ps2_key[8]<=keyhist[1]==8'he0||keyhist[2]==8'he0;
        if(keyhist[3]==8'he1) ps2_key[9:0]<=10'h377;
        else if(keyhist[2]==8'he0&&keyhist[1]==8'hf0&&keyhist[0]==8'h7c) ps2_key[9:0]<=10'h17c;
        else if(keyhist[1]==8'he0&&keyhist[0]==8'h7c) ps2_key[9:0]<=10'h37c;
      end
      if(cmd[7:0]==8'h22) RTC[64]<=~RTC[64]; if(cmd[7:0]==8'h24) TIMESTAMP[32]<=~TIMESTAMP[32];
    end
    if(old_fi&&!fi) begin
      fi_resp<=0; pos<=0;
      if(cmd[7:0]==8'h53) begin
        if(uart_mode_work[7:0]==0) begin if(ioctl_download) ioctl_addr<=ioctl_addr+(WIDE?2:1); ioctl_download<=0;ioctl_upload<=0;end
        else begin ioctl_upload<=uart_mode_work[7:0]==8'haa;ioctl_download<=uart_mode_work[7:0]!=8'haa; if(uart_mode_work[7:0]==8'haa) begin ioctl_rd<=1;upload_first<=1;end end
      end
    end
    if((io||fi)&&stb) begin
      if(pos==0) begin cmd<=din;pos<=1;discard<=0;io_resp<=0;fi_resp<=0;keyhist[0]<=0;keyhist[1]<=0;keyhist[2]<=0;keyhist[3]<=0;
        if(io) begin
          if(din[7:0]==8'h43) io_resp<=F12KEYMOD!=0;
`ifdef MISTER_DISABLE_ADAPTIVE
          if(din[7:0]==8'h2b) io_resp<={9'b0,HPS_BUS[48:46],4'h6};
`else
          if(din[7:0]==8'h2b) io_resp<={9'b0,HPS_BUS[48:46],4'h7};
`endif
          if(din[7:0]==8'h2f||din[7:0]==8'h39||din[7:0]==8'h3e)io_resp<=16'h0001;
          if(din[7:0]==8'h3f) io_resp<=rumble(din[11:8]);
          if(din[7:0]==8'h29) io_resp<={8'ha0,4'b0,generation};
          if(din[7:0]==8'h36) begin io_resp<={8'b0,pending_info};pending_info<=0;end
          if(din[7:0]==8'h32) io_resp<={15'b0,gamma_bus[21]};
          if(din[7:0]==8'h3c) begin io_resp<=upload_pending?{ioctl_upload_index,8'h01}:0;upload_pending<=0;end
          if(din[7:0]==8'h16) begin
            chosen=0;found=0;
            for(off=0;off<VDNUM;off=off+1) if(!found&&(sd_rd[(rr+off)%VDNUM]||sd_wr[(rr+off)%VDNUM])) begin chosen=(rr+off)%VDNUM;found=1;end
            selected_drive<=chosen;
            if(!found) io_resp<=16'h8000|(BLKSZ<<6);
            else io_resp<=16'h8000|(sd_blk_cnt[chosen]<<9)|(BLKSZ<<6)|(chosen<<2)|{sd_wr[chosen],sd_rd[chosen]};
          end
          if(din[7:0]==8'h17||din[7:0]==8'h18) begin sd_ack<={{(VDNUM-1){1'b0}},1'b1}<<din[11:8];sd_buff_addr<=0;selected_drive<=din[11:8];end
        end
      end else begin pos<=pos+1;
        if(io) case(cmd[7:0])
          8'h01: config_reg<=din;
          8'h02,8'h03,8'h10,8'h11,8'h12,8'h13: case(cmd[7:0])
            8'h02:if(pos==1)joystick_0[15:0]<=din;else joystick_0[31:16]<=din;8'h03:if(pos==1)joystick_1[15:0]<=din;else joystick_1[31:16]<=din;
            8'h10:if(pos==1)joystick_2[15:0]<=din;else joystick_2[31:16]<=din;8'h11:if(pos==1)joystick_3[15:0]<=din;else joystick_3[31:16]<=din;
            8'h12:if(pos==1)joystick_4[15:0]<=din;else joystick_4[31:16]<=din;default:if(pos==1)joystick_5[15:0]<=din;else joystick_5[31:16]<=din;endcase
          8'h14: if(pos<=STRLEN) begin if(CONF_STR_BRAM!=0)io_resp<={8'b0,conf_mem[pos-1]};else io_resp<={8'b0,CONF_STR[(STRLEN-pos)*8 +:8]};end else io_resp<=0;
          8'h1e: if(pos<=8) status[(pos-1)*16 +:16]<=din;
          8'h2e: io_resp<=pos==1?status_menumask:0;
          8'h31: if(pos==1)sdram_sz<=din;
          8'h1a: if(pos==1)uart_mode_work<=din;else if(pos==2) begin case(uart_mode_work[3:0])0:joystick_l_analog_0<=din;1:joystick_l_analog_1<=din;2:joystick_l_analog_2<=din;3:joystick_l_analog_3<=din;4:joystick_l_analog_4<=din;5:joystick_l_analog_5<=din;15:case(uart_mode_work[11:8])0:paddle_0<=din;1:paddle_1<=din;2:paddle_2<=din;3:paddle_3<=din;4:paddle_4<=din;5:paddle_5<=din;8:spinner_0<={~spinner_0[8],din[7:0]};9:spinner_1<={~spinner_1[8],din[7:0]};10:spinner_2<={~spinner_2[8],din[7:0]};11:spinner_3<={~spinner_3[8],din[7:0]};12:spinner_4<={~spinner_4[8],din[7:0]};13:spinner_5<={~spinner_5[8],din[7:0]};endcase endcase end
          8'h3d: if(pos==1)uart_mode_work<=din;else if(pos==2)case(uart_mode_work[3:0])0:joystick_r_analog_0<=din;1:joystick_r_analog_1<=din;2:joystick_r_analog_2<=din;3:joystick_r_analog_3<=din;4:joystick_r_analog_4<=din;5:joystick_r_analog_5<=din;endcase
          8'h04: if(din[15:8]==8'hff)discard<=1;else if(!discard)begin mouse_put<=1;mouse_put_data<=din[7:0];case(pos)1:begin mouse_b0<=din[7:0];mouse_ext_work[7:0]<={din[14],din[6:0]};end 2:begin mouse_b1<=din[7:0];mouse_ext_work[11:8]<=din[11:8];end 3:begin mouse_b2<=din[7:0];mouse_ext_work[15:12]<=din[11:8];end endcase end
          8'h05: if(din[15:8]==8'hff)discard<=1;else if(!discard)begin kbd_put<=1;kbd_put_data<=din[7:0];keyhist[3]<=keyhist[2];keyhist[2]<=keyhist[1];keyhist[1]<=keyhist[0];keyhist[0]<=din[7:0];end
          8'h1f: io_resp<=pos==1?{7'b0,(PS2WE!=0),2'b01,ps2_kbd_led_status[2],ps2_kbd_led_use[2],ps2_kbd_led_status[1],ps2_kbd_led_use[1],ps2_kbd_led_status[0],ps2_kbd_led_use[0]}:0;
          8'h21: if(pos==1)begin io_resp<={7'b0,kbd_rx_available,kbd_rx_data};kbd_take<=1;end else if(pos==2)begin io_resp<={7'b0,mouse_rx_available,mouse_rx_data};mouse_take<=1;end else io_resp<=0;
          8'h23: case(pos)
            1:io_resp<={6'b0,video_rotated,interlace,mode_generation};2:io_resp<=active_width[15:0];3:io_resp<=active_width[31:16];4:io_resp<=active_height[15:0];5:io_resp<=active_height[31:16];
            6:io_resp<=hs_period[15:0];7:io_resp<=hs_period[31:16];8:io_resp<=vs_period[15:0];9:io_resp<=vs_period[31:16];10:io_resp<=active_line_100[15:0];11:io_resp<=active_line_100[31:16];
            12:io_resp<=hdmi_vs_period[15:0];13:io_resp<=hdmi_vs_period[31:16];14:io_resp<=active_line_vid[15:0];15:io_resp<=active_line_vid[31:16];16:io_resp<={8'b0,pixel_spacing};17:io_resp<=de_start_h;18:io_resp<={8'b0,de_start_v};default:io_resp<=0;endcase
          8'h29: io_resp<=pos<=8?injected[(pos-1)*16 +:16]:0;
          8'h1c: begin img_mounted<=din[VDNUM-1:0]?din[VDNUM-1:0]:{{(VDNUM-1){1'b0}},1'b1};img_readonly<=din[7];end
          8'h1d: if(pos<=4)img_size[(pos-1)*16 +:16]<=din;
          8'h22: if(pos<=4)RTC[(pos-1)*16 +:16]<=din;
          8'h24: if(pos<=2)TIMESTAMP[(pos-1)*16 +:16]<=din;
          8'h32: gamma_en<=din[0];
          8'h33: begin gamma_wr<=1;case((pos-1)%3)0:gamma_addr<={2'b00,din[15:8]};1:gamma_addr<={2'b01,din[15:8]};default:gamma_addr<={2'b10,din[15:8]};endcase gamma_val<=din[7:0];end
          8'h3b: if(pos==1)uart_mode_work<=din;else if(pos==2)uart_speed[15:0]<=din;else if(pos==3)begin uart_mode<=uart_mode_work[7:0];uart_speed[31:16]<=din;end
          8'h16: begin if(pos==1)rr<=(selected_drive+1)%VDNUM;else if(pos==2)io_resp<=sd_lba[selected_drive][15:0];else if(pos==3)io_resp<=sd_lba[selected_drive][31:16];end
          8'h17: begin sd_buff_dout<=din[DW-1:0];sd_buff_wr<=1;if(pos>1&&!(&sd_buff_addr))sd_buff_addr<=sd_buff_addr+1'b1;end
          8'h18: begin io_resp<=sd_buff_din[selected_drive];if(pos>1&&!(&sd_buff_addr))sd_buff_addr<=sd_buff_addr+1'b1;end
        endcase
        else case(cmd[7:0])
          8'h55: ioctl_index<=din;
          8'h56: if(pos==1)ioctl_file_ext[31:16]<=din;else if(pos==2)ioctl_file_ext[15:0]<=din;
          8'h53: begin if(pos==1)begin uart_mode_work<=din;if(din[7:0]!=0)ioctl_addr<=0;end else if(pos==2)ioctl_addr[15:0]<=din;else if(pos==3)ioctl_addr[26:16]<=din[10:0];end
          8'h54: if(ioctl_download)begin ioctl_dout<=din[DW-1:0];ioctl_wr<=1;ioctl_addr<=ioctl_addr+(WIDE?2:1);end else if(ioctl_upload)begin fi_resp<=ioctl_din;ioctl_rd<=1;if(upload_first)upload_first<=0;else ioctl_addr<=ioctl_addr+(WIDE?2:1);end
        endcase
      end
    end
  end
endmodule

/* One endpoint of the optional, actively-driven PS/2 compatibility link. */
module mistfits_ps2_engine #(parameter integer DIV=1,RECEIVE_ENABLE=0)(
 input wire clk,input wire put,input wire[7:0] put_data,input wire take,
 output reg available=0,output reg[7:0] received=0,input wire clock_in,data_in,
 output wire clock_out,output reg data_out=1
);
 reg [7:0] fifo[0:31];reg[4:0] wp=0,rp=0;reg[5:0] count=0;reg[31:0] divider=0;reg phase=0;
 reg active=0,receiving=0;reg[3:0] step=0;reg[7:0] txbyte=0,rxwork=0;reg[1:0] qualification=0;
 reg cin1=1,cin2=1,cinold=1,din1=1;wire phase_rise=(divider==DIV)&&!phase;
 assign clock_out=active?phase:1'b1;
 always @(posedge clk) begin
   cin1<=RECEIVE_ENABLE?clock_in:1'b1;cin2<=cin1;cinold<=cin2;din1<=RECEIVE_ENABLE?data_in:1'b1;
   if(divider==DIV)begin divider<=0;phase<=~phase;end else divider<=divider+1;
   if(take)available<=0;
   if(put&&!available)begin fifo[wp]<=put_data;wp<=wp+1'b1;count<=count+1'b1;end
   if(!active&&RECEIVE_ENABLE&&!cinold&&cin2&&!din1)begin active<=1;receiving<=1;step<=0;data_out<=1;end
   if(phase_rise) begin
     if(!active&&count!=0&&cin2&&din1)begin
       if(qualification==0)begin active<=1;receiving<=0;step<=0;txbyte<=fifo[rp];rp<=rp+1'b1;count<=count-1'b1;data_out<=0;qualification<=3;end
       else qualification<=qualification-1'b1;
     end
     else if(active&&!receiving)begin
       if(step<8)data_out<=txbyte[step];
       else if(step==8)data_out<=~^txbyte;
       else data_out<=1;
       if(step==10)begin active<=0;step<=0;end else step<=step+1'b1;
     end else if(active&&receiving)begin
       if(step==0)step<=1;
       else if(step<=8)begin rxwork[step-1]<=din1;step<=step+1'b1;end
       else if(step==9)step<=10;
       else if(step==10)begin if(din1)begin data_out<=0;step<=11;end end
       else begin data_out<=1;received<=rxwork;available<=1;active<=0;receiving<=0;step<=0;wp<=0;rp<=0;count<=0;end
     end
   end
 end
endmodule
