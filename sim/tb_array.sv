`timescale 1ns/1ps
module tb_array;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,start=0;reg [7:0] k_count;
    wire re;wire [7:0] addr;reg [63:0] ad,wd;
    reg signed [7:0] x[0:143][0:7],wref[0:7][0:143];
    wire [63:0] a,w;wire [7:0] av,wv,al,wl;
    wire [2047:0] results;wire done;
    data_mapper mapper(clk,rst,start,k_count,re,addr,ad,wd,a,w,av,wv,al,wl);
    systolic_array array(clk,rst,start,a,w,av,wv,al,wl,results,done);
    integer i,j,k,t,cycles;reg signed [31:0] expected;
    always @(posedge clk) if(re) begin
        for(integer c=0;c<8;c=c+1) begin ad[c*8+:8]<=x[addr][c];wd[c*8+:8]<=wref[c][addr];end
    end
    initial begin
        repeat(4) @(negedge clk);rst=0;
        for(t=0;t<6;t=t+1) begin
            case(t%3) 0:k_count=9;1:k_count=72;2:k_count=144;endcase
            for(k=0;k<144;k=k+1) for(i=0;i<8;i=i+1) begin
                x[k][i]=((k*17+i*31+t*7)%255)-127;
                wref[i][k]=((k*43+i*13+t*11)%255)-127;
            end
            @(negedge clk);start=1;
            @(negedge clk);start=0;
            cycles=0;
            while(!done && cycles<200) begin @(negedge clk);cycles=cycles+1;end
            if(!done) $fatal(1,"array timeout K=%0d",k_count);
            for(i=0;i<8;i=i+1) for(j=0;j<8;j=j+1) begin
                expected=0;
                for(k=0;k<k_count;k=k+1) expected=expected+$signed(x[k][j])*$signed(wref[i][k]);
                if($signed(results[(i*8+j)*32+:32])!==expected)
                    $fatal(1,"array mismatch t=%0d r=%0d c=%0d actual=%0d expected=%0d",t,i,j,$signed(results[(i*8+j)*32+:32]),expected);
            end
            $display("PASS array K=%0d signed outputs=64 latency=%0d",k_count,cycles);
            repeat(3) @(negedge clk);
        end
        $display("PASS tb_array");$finish;
    end
endmodule
