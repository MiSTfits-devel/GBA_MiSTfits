/*
 * Copyright (c) 2026 MiSTfits contributors
 * Distributed under the zlib License. See LICENSE.
 *
 * Clean-room direct-video compatibility component.
 */
`timescale 1ns/1ps
module mistfits_direct_video_mixer #(
    parameter integer LINE_LENGTH = 768,
    parameter integer HALF_DEPTH = 0,
    parameter integer GAMMA = 0
) (
    input  wire        CLK_VIDEO,
    output reg         CE_PIXEL = 1'b0,
    input  wire        ce_pix,
    input  wire        scandoubler,
    input  wire        hq2x,
    inout  wire [21:0] gamma_bus,
    input  wire [7:0]  R,
    input  wire [7:0]  G,
    input  wire [7:0]  B,
    input  wire        HSync,
    input  wire        VSync,
    input  wire        HBlank,
    input  wire        VBlank,
    input  wire        HDMI_FREEZE,
    output wire        freeze_sync,
    output reg  [7:0]  VGA_R = 8'b0,
    output reg  [7:0]  VGA_G = 8'b0,
    output reg  [7:0]  VGA_B = 8'b0,
    output reg         VGA_VS = 1'b0,
    output reg         VGA_HS = 1'b0,
    output reg         VGA_DE = 1'b0
);
    assign gamma_bus[21] = (GAMMA != 0);
    assign freeze_sync = 1'b0;

    wire gamma_clock = gamma_bus[20];
    wire gamma_enable = gamma_bus[19];
    wire gamma_write = gamma_bus[18];
    wire [9:0] gamma_address = gamma_bus[17:8];
    wire [7:0] gamma_data = gamma_bus[7:0];

    reg [7:0] gamma_red [0:255];
    reg [7:0] gamma_green [0:255];
    reg [7:0] gamma_blue [0:255];
    always @(posedge gamma_clock) begin
        if (gamma_write) begin
            case (gamma_address[9:8])
                2'b00: gamma_red[gamma_address[7:0]] <= gamma_data;
                2'b01: gamma_green[gamma_address[7:0]] <= gamma_data;
                2'b10: gamma_blue[gamma_address[7:0]] <= gamma_data;
                default: ;
            endcase
        end
    end

    reg gamma_previous_ce = 1'b0;
    reg [7:0] gamma_r = 8'b0, gamma_g = 8'b0, gamma_b = 8'b0;
    reg gamma_hs = 1'b0, gamma_vs = 1'b0, gamma_hb = 1'b1, gamma_vb = 1'b1;
    generate if (GAMMA != 0) begin : gamma_pipeline
        always @(posedge CLK_VIDEO) begin
            gamma_previous_ce <= ce_pix;
            if (ce_pix && !gamma_previous_ce) begin
                gamma_r <= gamma_enable ? gamma_red[R] : R;
                gamma_g <= gamma_enable ? gamma_green[G] : G;
                gamma_b <= gamma_enable ? gamma_blue[B] : B;
                gamma_hs <= HSync;
                gamma_vs <= VSync;
                gamma_hb <= HBlank;
                gamma_vb <= VBlank;
            end
        end
    end endgenerate

    wire [7:0] selected_r = (GAMMA != 0) ? gamma_r : R;
    wire [7:0] selected_g = (GAMMA != 0) ? gamma_g : G;
    wire [7:0] selected_b = (GAMMA != 0) ? gamma_b : B;
    wire selected_hs = (GAMMA != 0) ? gamma_hs : HSync;
    wire selected_vs = (GAMMA != 0) ? gamma_vs : VSync;
    wire selected_hb = (GAMMA != 0) ? gamma_hb : HBlank;
    wire selected_vb = (GAMMA != 0) ? gamma_vb : VBlank;

    reg previous_ce = 1'b0;
    reg [7:0] sampled_r = 8'b0, sampled_g = 8'b0, sampled_b = 8'b0;
    reg sampled_hs = 1'b0, sampled_vs = 1'b0;
    reg sampled_hb = 1'b1, sampled_vb = 1'b1;
    reg transitions_seen = 1'b0;
    reg edge_enable_policy = 1'b0;
    reg accepted_horizontal_active = 1'b0;

    wire ce_changed = ce_pix != previous_ce;
    wire frame_marker = selected_vs && !sampled_vs;
    wire rising_ce = ce_pix && !previous_ce;
    wire next_ce = edge_enable_policy ? rising_ce : ce_pix;
    wire delayed_horizontal_active = !sampled_hb;
    wire horizontal_changed = delayed_horizontal_active != accepted_horizontal_active;

    always @(posedge CLK_VIDEO) begin
        previous_ce <= ce_pix;
        sampled_r <= selected_r;
        sampled_g <= selected_g;
        sampled_b <= selected_b;
        sampled_hs <= selected_hs;
        sampled_vs <= selected_vs;
        sampled_hb <= selected_hb;
        sampled_vb <= selected_vb;
        CE_PIXEL <= next_ce;

        if (frame_marker) begin
            edge_enable_policy <= transitions_seen || ce_changed;
            transitions_seen <= 1'b0;
        end else begin
            transitions_seen <= transitions_seen || ce_changed;
        end

        if (CE_PIXEL) begin
            VGA_R <= sampled_r;
            VGA_G <= sampled_g;
            VGA_B <= sampled_b;
            VGA_HS <= sampled_hs;
            VGA_VS <= sampled_vs;
            if (horizontal_changed) begin
                accepted_horizontal_active <= delayed_horizontal_active;
                VGA_DE <= !sampled_vb && delayed_horizontal_active;
            end
        end
    end

    // Compatibility inputs intentionally have no behavioral effect:
    // LINE_LENGTH, HALF_DEPTH, scandoubler, hq2x, and HDMI_FREEZE.
endmodule
