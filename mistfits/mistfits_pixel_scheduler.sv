/* Copyright (c) 2026 MiSTfits contributors. zlib License; see LICENSE. */
`timescale 1ns/1ps
module mistfits_pixel_scheduler(input wire clk,input wire restart,input wire hq,input wire[7:0] interval,output reg engine_enable=0,output reg CE_PIXEL=0,output reg transaction=0,output reg[7:0] position=0);
 wire[7:0] j=position+1'b1;wire[7:0] q=interval>>2,h=interval>>1;
 wire four=(j==q)||(j==h)||(j==q+h)||(j==interval);wire two=(j==h)||(j==interval);
 always @(posedge clk)begin
  transaction<=CE_PIXEL;CE_PIXEL<=engine_enable;
  if(restart)begin position<=0;engine_enable<=1;end
  else begin engine_enable<=hq?four:two;if(j>=interval)position<=0;else position<=j;end
 end
endmodule
