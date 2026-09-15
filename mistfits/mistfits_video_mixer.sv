/* Copyright (c) 2026 MiSTfits contributors. zlib License; see LICENSE. */
`timescale 1ns/1ps
module mistfits_doubled_timing(
 input wire clk,input wire hs,input wire vs,input wire hb,input wire vb,input wire four_event,
 output wire out_hs,output wire out_vs,output wire out_hb,output wire out_vb,
 output reg line_boundary=0,output reg hs_rise_boundary=0,output reg[1:0] line_selector=0
);
 reg hs_d=0,hb_d=1;
 reg[31:0] C=0;reg[30:0] O=0,L=0,A=0,SR=0,SF=0;
 reg base_hb=1,base_hs=0;
 reg[8:0] hb_history=9'h1ff;reg[3:0] vs_history=0,vb_history=4'hf;
 wire hb_fall=hb_d&&!hb;
 wire hb_rise=!hb_d&&hb;
 wire hs_rise=!hs_d&&hs;
 wire hs_fall=hs_d&&!hs;
 always @(posedge clk) begin
  hs_d<=hs;hb_d<=hb;line_boundary<=0;hs_rise_boundary<=0;
  C<=C+1'b1;
  if(hb_fall)begin L<=C>>1;C<=0;vb_history[0]<=vb;end
  if(hb_rise)A<=C>>1;
  if(hs_rise)SR<=C>>1;
  if(hs_fall)begin SF<=C>>1;vs_history[0]<=vs;end
  O<=O+1'b1;
  if(O==L)begin
   O<=0;base_hb<=0;line_boundary<=1;
   vb_history[1]<=vb_history[0];vb_history[2]<=vb_history[1];vb_history[3]<=vb_history[2];
  end
  if(O==A)base_hb<=1;
  if(O==SR)begin base_hs<=1;hs_rise_boundary<=1;end
  if(O==SF)begin
   base_hs<=0;vs_history[1]<=vs_history[0];vs_history[2]<=vs_history[1];vs_history[3]<=vs_history[2];
   if(&vb_history[1:0])line_selector<=1;else line_selector<=line_selector+1'b1;
  end
  if(four_event)hb_history<={hb_history[7:0],base_hb};
 end
 assign out_hb=hb_history[6];assign out_hs=base_hs;assign out_vs=vs_history[3];assign out_vb=vb_history[3];
endmodule

module mistfits_video_mixer #(
 parameter integer LINE_LENGTH=768, HALF_DEPTH=0, GAMMA=0
)(
 input wire CLK_VIDEO,output wire CE_PIXEL,input wire ce_pix,input wire scandoubler,hq2x,
 inout wire[21:0] gamma_bus,input wire[(HALF_DEPTH?4:8)-1:0] R,G,B,
 input wire HSync,VSync,HBlank,VBlank,HDMI_FREEZE,output reg freeze_sync=0,
 output wire[7:0] VGA_R,VGA_G,VGA_B,output wire VGA_VS,VGA_HS,VGA_DE
);
 reg freeze_d1=0,freeze_d2=0;
 always @(posedge CLK_VIDEO)begin freeze_d1<=HDMI_FREEZE;freeze_d2<=freeze_d1;end
 wire[7:0] expanded_r=HALF_DEPTH?{R[3:0],R[3:0]}:R;
 wire[7:0] expanded_g=HALF_DEPTH?{G[3:0],G[3:0]}:G;
 wire[7:0] expanded_b=HALF_DEPTH?{B[3:0],B[3:0]}:B;
 wire[7:0] core_r=freeze_d2?0:expanded_r;
 wire[7:0] core_g=freeze_d2?0:expanded_g;
 wire[7:0] core_b=freeze_d2?0:expanded_b;
 wire[7:0] out_r,out_g,out_b;wire native_ce,native_hs,native_vs,native_de;
 reg hs_d=0,vs_d=0,hb_d=0,vb_d=0,freeze_d=0;
 reg[31:0] live_hc=0,live_vc=0,hs_period=0,vs_period=0,hs_fall=0;
 reg[31:0] hb_rise=0,hb_fall=0,vb_rise=0,vb_fall=0;
 reg[31:0] gen_hc=0,gen_vc=0;reg gen_hs=0,gen_vs=0,gen_hb=0,gen_vb=0;
 reg marker=0,gen_vs_d=0,pending_frame=0;reg timing_valid=0;reg[1:0] hs_periods=0,vs_periods=0;
 wire selected_hs=HDMI_FREEZE&&timing_valid?gen_hs:HSync;
 wire selected_vs=HDMI_FREEZE&&timing_valid?gen_vs:VSync;
 wire selected_hb=HDMI_FREEZE&&timing_valid?gen_hb:HBlank;
 wire selected_vb=HDMI_FREEZE&&timing_valid?gen_vb:VBlank;
 wire gamma_clock=gamma_bus[20],gamma_enable=gamma_bus[19],gamma_write=gamma_bus[18];wire[9:0] gamma_address=gamma_bus[17:8];wire[7:0] gamma_data=gamma_bus[7:0];
 reg[7:0] scan_gamma_r[0:255],scan_gamma_g[0:255],scan_gamma_b[0:255];
 always @(posedge gamma_clock)if(gamma_write)case(gamma_address[9:8])0:scan_gamma_r[gamma_address[7:0]]<=gamma_data;1:scan_gamma_g[gamma_address[7:0]]<=gamma_data;2:scan_gamma_b[gamma_address[7:0]]<=gamma_data;default:;endcase
 wire[7:0] scan_r=(GAMMA!=0&&gamma_enable)?scan_gamma_r[core_r]:core_r;
 wire[7:0] scan_g=(GAMMA!=0&&gamma_enable)?scan_gamma_g[core_g]:core_g;
 wire[7:0] scan_b=(GAMMA!=0&&gamma_enable)?scan_gamma_b[core_b]:core_b;
 reg[7:0] line_r0[0:LINE_LENGTH-1],line_g0[0:LINE_LENGTH-1],line_b0[0:LINE_LENGTH-1];
 reg[7:0] line_r1[0:LINE_LENGTH-1],line_g1[0:LINE_LENGTH-1],line_b1[0:LINE_LENGTH-1];
 reg[7:0] line_r2[0:LINE_LENGTH-1],line_g2[0:LINE_LENGTH-1],line_b2[0:LINE_LENGTH-1];
 reg[1:0] write_bank=0,read_bank=0,top_bank=0,bottom_bank=0,prev_bank=0,prevprev_bank=0;reg[1:0] lines_seen=0;reg ce_d=0,hblank_d=1;integer write_count=0,read_count=0,line_length=0;
 reg pixel_repeat=0,output_line=0,doubler_active=0,doubler_active_d=0,output_armed=0,output_write=0;reg[15:0] ce_interval=0;reg[7:0] learned_interval=4;reg learner_valid=0,input_hs_d=0;
 reg doubler_ce=0;reg[7:0] doubler_r=0,doubler_g=0,doubler_b=0;
 // Quartus 17 cannot reliably map a variable-index RAM read hidden inside an
 // automatic function containing bank selection and RGB concatenation. Give
 // every bank/channel/position an explicit read expression, then mux only the
 // already-read packed pixels. Boundary addresses are clamped before indexing;
 // validity muxes retain the specified black neighborhood edges.
 wire hq_left_valid=(read_count>0),hq_center_valid=(read_count<line_length),hq_right_valid=(read_count+1<line_length);
 wire[31:0] hq_left_addr=hq_left_valid?read_count-1:0;
 wire[31:0] hq_center_addr=hq_center_valid?read_count:0;
 wire[31:0] hq_right_addr=hq_right_valid?read_count+1:0;
 wire[7:0] r0l=line_r0[hq_left_addr],g0l=line_g0[hq_left_addr],b0l=line_b0[hq_left_addr];
 wire[7:0] r0c=line_r0[hq_center_addr],g0c=line_g0[hq_center_addr],b0c=line_b0[hq_center_addr];
 wire[7:0] r0r=line_r0[hq_right_addr],g0r=line_g0[hq_right_addr],b0r=line_b0[hq_right_addr];
 wire[7:0] r1l=line_r1[hq_left_addr],g1l=line_g1[hq_left_addr],b1l=line_b1[hq_left_addr];
 wire[7:0] r1c=line_r1[hq_center_addr],g1c=line_g1[hq_center_addr],b1c=line_b1[hq_center_addr];
 wire[7:0] r1r=line_r1[hq_right_addr],g1r=line_g1[hq_right_addr],b1r=line_b1[hq_right_addr];
 wire[7:0] r2l=line_r2[hq_left_addr],g2l=line_g2[hq_left_addr],b2l=line_b2[hq_left_addr];
 wire[7:0] r2c=line_r2[hq_center_addr],g2c=line_g2[hq_center_addr],b2c=line_b2[hq_center_addr];
 wire[7:0] r2r=line_r2[hq_right_addr],g2r=line_g2[hq_right_addr],b2r=line_b2[hq_right_addr];
 wire[23:0] p0l=hq_left_valid?{r0l,g0l,b0l}:0,p0c=hq_center_valid?{r0c,g0c,b0c}:0,p0r=hq_right_valid?{r0r,g0r,b0r}:0;
 wire[23:0] p1l=hq_left_valid?{r1l,g1l,b1l}:0,p1c=hq_center_valid?{r1c,g1c,b1c}:0,p1r=hq_right_valid?{r1r,g1r,b1r}:0;
 wire[23:0] p2l=hq_left_valid?{r2l,g2l,b2l}:0,p2c=hq_center_valid?{r2c,g2c,b2c}:0,p2r=hq_right_valid?{r2r,g2r,b2r}:0;
 reg[23:0] hqa,hqb,hqc,hqd,hqe,hqf,hqg,hqh,hqi;
 always @* begin
  case(top_bank)0:begin hqa=p0l;hqb=p0c;hqc=p0r;end 1:begin hqa=p1l;hqb=p1c;hqc=p1r;end default:begin hqa=p2l;hqb=p2c;hqc=p2r;end endcase
  case(read_bank)0:begin hqd=p0l;hqe=p0c;hqf=p0r;end 1:begin hqd=p1l;hqe=p1c;hqf=p1r;end default:begin hqd=p2l;hqe=p2c;hqf=p2r;end endcase
  case(bottom_bank)0:begin hqg=p0l;hqh=p0c;hqi=p0r;end 1:begin hqg=p1l;hqh=p1c;hqi=p1r;end default:begin hqg=p2l;hqh=p2c;hqi=p2r;end endcase
 end
 wire[23:0] hqtl,hqtr,hqbl,hqbr;wire[7:0] hqmask;
 mistfits_hq2x hq_transform(hqa,hqb,hqc,hqd,hqe,hqf,hqg,hqh,hqi,hqtl,hqtr,hqbl,hqbr,hqmask);
 wire scheduler_engine,scheduler_ce,scheduler_transaction;wire[7:0] scheduler_position;
 wire timing_hs,timing_vs,timing_hb,timing_vb,timing_line_boundary,timing_hs_rise;wire[1:0] timing_line_selector;
 mistfits_doubled_timing timing_recurrence(CLK_VIDEO,selected_hs,selected_vs,selected_hb,selected_vb,scheduler_engine,timing_hs,timing_vs,timing_hb,timing_vb,timing_line_boundary,timing_hs_rise,timing_line_selector);
 wire output_reanchor=timing_hs_rise;
 mistfits_pixel_scheduler output_scheduler(CLK_VIDEO,output_reanchor,hq2x,learned_interval,scheduler_engine,scheduler_ce,scheduler_transaction,scheduler_position);
 always @(posedge CLK_VIDEO)begin
  ce_d<=ce_pix;hblank_d<=selected_hb;input_hs_d<=selected_hs;doubler_active_d<=doubler_active;doubler_ce<=0;output_write<=0;ce_interval<=ce_interval+1'b1;
  if(selected_hb||selected_vb)learner_valid<=0;
  if(!input_hs_d&&selected_hs)ce_interval<=0;
  if(!ce_d&&ce_pix)begin
   if(!selected_hb&&!selected_vb&&write_count<LINE_LENGTH)begin
    case(write_bank)0:begin line_r0[write_count]<=scan_r;line_g0[write_count]<=scan_g;line_b0[write_count]<=scan_b;end 1:begin line_r1[write_count]<=scan_r;line_g1[write_count]<=scan_g;line_b1[write_count]<=scan_b;end default:begin line_r2[write_count]<=scan_r;line_g2[write_count]<=scan_g;line_b2[write_count]<=scan_b;end endcase
    write_count<=write_count+1;
   end
   if(!selected_hb&&!selected_vb)begin
    if(learner_valid&&ce_interval+1>=4&&ce_interval+1<=255)learned_interval<=ce_interval+1;
    learner_valid<=1;ce_interval<=0;
   end
  end
  if(selected_vb)begin lines_seen<=0;prev_bank<=0;prevprev_bank<=0;doubler_active<=0;output_armed<=0;end
  if(!hblank_d&&selected_hb&&write_count!=0)begin
   line_length<=write_count;write_count<=0;read_count<=0;pixel_repeat<=0;output_line<=0;output_armed<=0;
   if(hq2x)begin top_bank<=prevprev_bank;read_bank<=prev_bank;bottom_bank<=write_bank;doubler_active<=lines_seen>=2;prevprev_bank<=prev_bank;prev_bank<=write_bank;if(lines_seen<3)lines_seen<=lines_seen+1'b1;end
   else begin read_bank<=write_bank;doubler_active<=1;end
   if(write_bank==2)write_bank<=0;else write_bank<=write_bank+1'b1;
  end
  if(doubler_active&&scheduler_transaction)begin
   if(!output_armed)output_armed<=1;else begin output_write<=1;
    doubler_ce<=1;
    if(hq2x)begin if(!output_line&&!pixel_repeat){doubler_r,doubler_g,doubler_b}<=hqtl;else if(!output_line){doubler_r,doubler_g,doubler_b}<=hqtr;else if(!pixel_repeat){doubler_r,doubler_g,doubler_b}<=hqbl;else {doubler_r,doubler_g,doubler_b}<=hqbr;end
    else case(read_bank)0:begin doubler_r<=line_r0[read_count];doubler_g<=line_g0[read_count];doubler_b<=line_b0[read_count];end 1:begin doubler_r<=line_r1[read_count];doubler_g<=line_g1[read_count];doubler_b<=line_b1[read_count];end default:begin doubler_r<=line_r2[read_count];doubler_g<=line_g2[read_count];doubler_b<=line_b2[read_count];end endcase
    if(pixel_repeat)begin pixel_repeat<=0;if(read_count==line_length-1)begin
      read_count<=0;if(output_line)begin output_line<=0;doubler_active<=0;end else output_line<=1;
    end else read_count<=read_count+1;end else pixel_repeat<=1;
   end
  end
 end
 always @(posedge CLK_VIDEO) begin
  hs_d<=HSync;vs_d<=VSync;hb_d<=HBlank;vb_d<=VBlank;freeze_d<=HDMI_FREEZE;gen_vs_d<=gen_vs;marker<=0;
  if(!HDMI_FREEZE) begin
   live_hc<=live_hc+1;live_vc<=live_vc+1;
   if(!hs_d&&HSync)begin hs_period<=live_hc;live_hc<=0;if(hs_periods!=3)hs_periods<=hs_periods+1'b1;end
   if(hs_d&&!HSync)hs_fall<=live_hc;
   if(!hb_d&&HBlank)hb_rise<=live_hc;if(hb_d&&!HBlank)hb_fall<=live_hc;
   if(!vs_d&&VSync)begin vs_period<=live_vc;live_vc<=0;if(vs_periods!=3)vs_periods<=vs_periods+1'b1;end
   if(!vb_d&&VBlank)vb_rise<=live_vc;if(vb_d&&!VBlank)vb_fall<=live_vc;
   timing_valid<=(hs_periods>=2&&vs_periods>=2);gen_hs<=HSync;gen_vs<=VSync;gen_hb<=HBlank;gen_vb<=VBlank;
   gen_hc<=live_hc;gen_vc<=live_vc;pending_frame<=0;
  end else if(timing_valid) begin
   if(gen_hc==hs_period)begin gen_hc<=0;gen_hs<=1;end else begin gen_hc<=gen_hc+1;if(gen_hc==hs_fall)gen_hs<=0;end
   if(gen_hc==hb_rise)gen_hb<=1;if(gen_hc==hb_fall)gen_hb<=0;
   if(gen_vc==vs_period)begin gen_vc<=0;gen_vs<=1;end else gen_vc<=gen_vc+1;
   if(gen_vc==vb_rise)gen_vb<=1;if(gen_vc==vb_fall)gen_vb<=0;
   if(gen_hc==(hs_fall>>1))marker<=1;
   if(!gen_vs_d&&gen_vs)pending_frame<=1;
   if(marker&&pending_frame)begin freeze_sync<=~freeze_sync;pending_frame<=0;end
  end
 end
 assign CE_PIXEL=scandoubler?((doubler_active||doubler_active_d)?scheduler_ce:1'b0):native_ce;
 wire[7:0] scan_out_r=(HALF_DEPTH!=0&&GAMMA==0)?{doubler_r[7:4],doubler_r[7:4]}:doubler_r;
 wire[7:0] scan_out_g=(HALF_DEPTH!=0&&GAMMA==0)?{doubler_g[7:4],doubler_g[7:4]}:doubler_g;
 wire[7:0] scan_out_b=(HALF_DEPTH!=0&&GAMMA==0)?{doubler_b[7:4],doubler_b[7:4]}:doubler_b;
 assign VGA_R=scandoubler?scan_out_r:out_r;
 assign VGA_G=scandoubler?scan_out_g:out_g;
 assign VGA_B=scandoubler?scan_out_b:out_b;
 assign VGA_HS=scandoubler?timing_hs:native_hs;
 assign VGA_VS=scandoubler?timing_vs:native_vs;
 assign VGA_DE=scandoubler?(!timing_hb&&!timing_vb):native_de;
 mistfits_direct_video_mixer #(.LINE_LENGTH(LINE_LENGTH),.HALF_DEPTH(HALF_DEPTH),.GAMMA(GAMMA)) core(
  .CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(native_ce),.ce_pix(ce_pix),.scandoubler(1'b0),.hq2x(1'b0),.gamma_bus(gamma_bus),
  .R(core_r),.G(core_g),.B(core_b),.HSync(selected_hs),.VSync(selected_vs),.HBlank(selected_hb),.VBlank(selected_vb),.HDMI_FREEZE(1'b0),
  .freeze_sync(),.VGA_R(out_r),.VGA_G(out_g),.VGA_B(out_b),.VGA_VS(native_vs),.VGA_HS(native_hs),.VGA_DE(native_de));
endmodule
