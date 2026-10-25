`timescale 1ns/1ps
module systolic_array(
    input wire clk, rst, clear,
    input wire [63:0] activations, weights,
    input wire [7:0] av, wv, al, wl,
    output wire [2047:0] results,
    output wire done
);
    wire [7:0] a [0:71];
    wire [7:0] w [0:71];
    wire va[0:71], vw[0:71], la[0:71], lw[0:71];
    wire [63:0] pe_done;
    genvar r,c;
    generate
        for(c=0;c<8;c=c+1) begin: a_boundary
            assign a[c]=activations[c*8+:8];
            assign va[c]=av[c]; assign la[c]=al[c];
        end
        for(r=0;r<8;r=r+1) begin: rows
            assign w[r*9]=weights[r*8+:8];
            assign vw[r*9]=wv[r]; assign lw[r*9]=wl[r];
            for(c=0;c<8;c=c+1) begin: cols
                mac_pe pe(
                    .clk(clk),.rst(rst),.clear(clear),
                    .a_in(a[r*8+c]),.w_in(w[r*9+c]),
                    .a_valid(va[r*8+c]),.w_valid(vw[r*9+c]),
                    .a_last(la[r*8+c]),.w_last(lw[r*9+c]),
                    .a_out(a[(r+1)*8+c]),.w_out(w[r*9+c+1]),
                    .av_out(va[(r+1)*8+c]),.wv_out(vw[r*9+c+1]),
                    .al_out(la[(r+1)*8+c]),.wl_out(lw[r*9+c+1]),
                    .psum(results[(r*8+c)*32+:32]),.done(pe_done[r*8+c]));
            end
        end
    endgenerate
    assign done=pe_done[63];
endmodule
