# sump2
SUMP2 an open-source software and hardware logic analyzer

File List:

  sump2.v      : Verilog IP for an FPGA ( or ASIC ) compact and scalable Logic Analyzer.
  
  sump2.py     : The Python PyGame GUI software for setting triggers and downloading and viewing waveforms.
  
  bd_server.py : TCP/IP server interface to FTDI USB Serial for sump2.py on PC platforms.

sump2 project is created by Kevin Hubbard of BlackMesaLabs.

Note : I have not uploaded the entire FPGA design files yet ( including the Mesa Bus Protocol stuff )

sump2 FPGA firmware is running on 2 different platforms ( iCEstick and IcoBoard ) and is slightly

different for the two platforms, so I need to sort that out still.

All of the design files are still available, just in my public DropBox account. See:

https://blackmesalabs.wordpress.com/2016/12/22/sump2-100-msps-32bit-logic-analyzer-for-icoboardraspberrypi/

https://blackmesalabs.wordpress.com/2016/10/24/sump2-96-msps-logic-analyzer-for-22/


Regarding my coding style, I have a coding style that I apply to all my source files. 

My rules are non-pythonic, and are applied to Python,C,Verilog,VHDL,Perl equally.

My Python does not "look" like others Python, but it does look like my Verilog,C,etc.

Rule-1 : \<TAB> is never to be used. Two space "  " indents only.

Rule-2 : All text lines are 80 columns wide maximum, including the \<CR>\<LF>.

Rule-3 : All instruction lines end in a ";" even though not required.


Why do I have these rules? I write primarily in Verilog and always use 2 side-by-side

Vim sessions in a Linux desktop that are always 80 columns wide. It is natural for me

to apply the same rules to everything that I write, so I do.



EOF
