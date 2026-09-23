;***************************************************************************************************
;*
;* Misto			: CVUT FEL, Katedra Mereni
;* Prednasejici		: Doc. Ing. Jan Fischer,CSc.
;* Predmet			: NVS
;* Vyvojovy Kit		: STM32 VL DISCOVERY (STM32F100RB)
;*
;**************************************************************************************************
;*
;* JMÉNO SOUBORU	: LCD_ENC.ASM
;* AUTOR			: Petr Pojar
;* DATUM			: 27/11/2025
;* POPIS			: Program schdistoveho automatu
;*					  - zobrazeni casu a jmena na LCD displeji s posuvnym registrem 
;*					  - komunikace a moznost nastaveni pres UART v terminalu
;*					  - enkoder, tlacitka, zakladni funkce schodistoveho automatu
;*					  - zapis nastaveneho casu do pameti FLASH

;***************************************************************************************************
				
		AREA    STM32F1xx, CODE, READONLY  	; hlavicka souboru
	
		GET		INI.s					; vlozeni souboru s pojmenovanymi adresami
										; jsou zde definovany adresy pristupu do pameti (k registrum)
										
moje_RAM 		EQU 	0x20001000
flashidx_RAM 	EQU 	0x20001008

flash_page 	EQU		 0x08007C00		; 31. strana flash pameti
flashidx_max EQU	0x08007FFF

DEFAULT_TIME EQU 	10				; defaultni hodnota casu po zapnuti
BUTTON_TIME EQU 	300				; konstanta pro kontrolu delky stisku tlacitka, 300 odpovida 0.6 sec protoze jedna iterace LOOP trva 2 ms
DOBA	EQU			0x1F40			; direktiva EQU priradi vyrazu 'doba' hodnotu 10000 hexadecimálnì
DOBA_2MS EQU		0x3E80
DOBA_3S EQU			0x16E3600
LEDPC8	EQU			0x08 			; LED je na PC8
LEDPC9	EQU			0x09 			; LED je na PC9	
	
; stavy automatu
state_available EQU 0x0
state_setting EQU 	0x1
state_running EQU 	0x2
	
; stav svetel (modra led)
light_off EQU 		0x0				; svetlo zhasle
light_on EQU 		0x1				; svetlo rozsvicene
	
; generator znaku
nula 	EQU 	2_00000011
jednicka EQU 	2_10011111
dvojka 	EQU 	2_00100101
trojka 	EQU 	2_00001101
ctyrka 	EQU 	2_10011001
petka 	EQU 	2_01001001
sestka 	EQU 	2_01000001
sedmicka EQU 	2_00011111 
osmicka EQU 	2_00000001
devitka EQU 	2_00001001
tecka 	EQU 	2_11111110	 
											
		EXPORT	__main					; export navesti pouzivaneho v jinem souboru, zde konkretne
		EXPORT	__use_two_region_memory	; jde o navesti, ktere pouziva startup code STM32F10x.s
		
__use_two_region_memory	
__main								  						
		
		ENTRY							; vstupni bod do kodu, odtud se zacina vykonavat program

;***************************************************************************************************
;* Jmeno funkce		: MAIN
;* Popis			: Hlavni program + volani podprogramu nastaveni hodinoveho systemu, konfigurace
;*					  pouzitych vyvodu procesoru a rutina pro sofwarove spozdeni	
;* Vstup			: Zadny
;* Vystup			: Zadny
;***************************************************************************************************

MAIN									; MAIN navesti hlavni smycky programu	blikej										
				BL		RCC_CNF			; Volani podprogramu nastaveni hodinoveho systemu procesoru
										; tj. skok na adresu s navestim RCC_CNF a ulozeni navratove 
										; adresy do LR (Link Register)

				BL		GPIO_CNF		; Volani podprogramu konfigurace vyvodu procesoru
										; tj. skok na adresu s navestim GPIO_CNF 
										;*!* Poznamka pri pouziti volani podprogramu instrukci BL nesmi
										; byt v obsluze podprogramu tato instrukce jiz pouzita, nebot
										; by doslo k prepsani LR a ztrate navratove adresy ->
										; lze ale pouzit i jine instrukce (PUSH, POP) *!*
				BL 		TIMER3_CNF 		; nastaveni timeru 3 pro encoder
				BL		FLASH_CNF		; nastaveni zapisu a cteni z/do flash, zapis aktualni adresy flash do RAM
				BL 		USART_CNF 		; nastaveni usart pro prijem i vysilani
				
				;LDR R3, =0x3D0900 ; 500 ms
				;BL DELAY
				
				MOV 	R0, #state_available ; R0 obsahuje aktualni stav automatu (available/running/setting)
				;MOV 	R4, #DEFAULT_TIME	; nastaveny cas pro zobrazeni na displeji, bude mozno menit uzivatelem
				;MOV 	R5, #DEFAULT_TIME	; SW counter pro cas (sec), odcitani od nastavene konstanty v R4, nastavi se v CONTROL
				MOV 	R5, R4	; SW counter pro cas (sec), odcitani od nastavene konstanty v R4, nastavi se v CONTROL
				MOV 	R6, #0 			; stav tlacitek v predchozi iteraci
				MOV 	R7, #0			; SW citac pro tlacitka, inkrementace pokud je stiskle
				;MOV 	R8, #0			; SW citac rychly, inkrementace v kayde iteraci (1 ms), nastavi se v CONTROL
				MOV 	R9, #0			; hodnota aktivniho tlacitka (ktere je prave stiskle) (mohlo by byt v pameti a ne
										; v registru, pokud by bylo malo reg, stejne tak R4 a R5)
				MOV 	R10, #light_off	; stav svetel (modra LED), nastaveni na zhasnute
				
				; kontrola, jestli je stiskle user button po resetu, pokud ano, provede se smazani stranky flash
				LDR		R2, =GPIOA_IDR 	; Kopie adresy brany A IDR do R5, GPIOA_IDR je v souboru INI.S			
				LDR		R1, [R2]		; Nacteni obsahu registru na adrese v R2 do R1, tj. cteni brany A
				TST		R1, #0x1			; sestupna hrana na tlacitku PA0 (user button)
				BEQ 	NOERASE			; skok, pokud neni R1 & 0x1 shodne
				; chceme smazat uzivatleskou flash:
				BL FLASH_ERASE
				BL LEDG_ON
				LDR R3, =DOBA_3S
				BL DELAY
				BL LEDG_OFF
NOERASE			

				BL 		FLASH_LOADTIME 		; nacteni ulozene hodnoty casu z flash
				
				BL TO_DECADIC
				BL LCD_INIT
				
				LDR 	R3, =ansi_clear			; nacteni adresy retezce, clear terminalu
				BL		TRAN_USART_TEXT			; vyslani textoveho retezce
				
				LDR		R3, =ansi_home			; nacteni adresy retezce
				BL		TRAN_USART_TEXT			; vyslani textoveho retezce
				
				LDR		R3, =hlaseni_usarton	; nacteni adresy retezce
				BL		TRAN_USART_TEXT			; vyslani textoveho retezce
				
				LDR		R3, =ansi_row3			; nacteni adresy retezce
				BL		TRAN_USART_TEXT			; vyslani textoveho retezce
				
				LDR		R3, =hlaseni_name		; nacteni adresy retezce
				BL		TRAN_USART_TEXT			; vyslani textoveho retezce
				
				LDR		R3, =ansi_hidec			; nacteni adresy retezce
				BL		TRAN_USART_TEXT			; vyslani textoveho retezce	

		
				
				
				B SKIP_LTORG
				LTORG
SKIP_LTORG		
				
CONTROL
				;automat dojel do konce, zhasnou LED, na displej defaultni hodnota, reset stavu automatu a svetel
				MOV R0, #state_available ; automat do defaultniho stavu
				MOV R10, #light_off		; svetla do stavu "zhasnuto"
				BL LEDG_OFF				; zhasni zelenou LED
				BL LEDB_OFF				; zhasni modrou LED
				MOV R8, #0				; nulovani rychleho SW countru
				MOV R5, R4				; SW counter, odcitani od nastavene konstanty v R4, navrat na pocatecni hodnotu
				BL TO_DECADIC				; spocte pro registry R4 a R5 desitky a jednotky, ulozeni do moje_RAM
				BL LCD_DISPTIME
				BL USART_DISPTIME
				
LOOP			; Navesti LOOP hlani smycky	
				
				MOV R3, #DOBA_2MS
				BL DELAY				; cekani 1 ms, aby bylo cislo na displeji viditelne
				
				; cteni USART *******************************
				BL REC_USART
				
				; cteni tlacitek ****************************	
				LDR		R2, =GPIOA_IDR 	; Kopie adresy brany A IDR do R5, GPIOA_IDR je v souboru INI.S			
				LDR		R1, [R2]		; Nacteni obsahu registru na adrese v R2 do R1, tj. cteni brany A
				MOV 	R2, #0xFFE0
				BIC 	R1, R1, R2		; maska na prvnich 5 bitu (PA0-PA4)
				EOR 	R1, R1, #0x10	; negace bitu 4, na PA 4 je tlacitko enkoderu
				;AND 	R3, R1, R6		; R3 = R1 & R6, tj. data z IDR & IDR z predchozi iterace
				;MOV 	R6, R1			; ulozeni hodnoty IDR z aktualni iterace do R6 pro pristi iteraci
				
				; vyhodnoceni stisku obou (+/-) tlacitek zaroven
				CMP R1, #2_1100
				BNE SKIP_OBE
				; obe stiskla
				MOV R9, #2
				B SKIP_TL
SKIP_OBE
				
				; vyhodnoceni jednotlivych tlacitek
				CMP 	R1, R6
				BLO 	SEST_HRANA
				BHI		NABEZ_HRANA	
				; beze zmeny - skok na konec bloku s tlacitky
				B SKIP_TL

SEST_HRANA
				TST		R6, #0x1			; sestupna hrana na tlacitku PA0 (user button)
				BEQ 	NENI_TL0			; skok, pokud neni R3 & 0x1 shodne
				; je sest hrana na tl. 0
				;MOV 	R7, #0		; nulovani citace
				MOV 	R10, #light_on ; nastaveni stavu "svetel" na zapnuto
				BL LEDB_ON				; aktivace modre LEDky ("svetla sviti")
				MOV R5, R4				; SW counter, odcitani od nastavene konstanty v R4, navrat na pocatecni hodnotu
				MOV R8, #0				; nulovani SW counteru
				BL TO_DECADIC
				BL LCD_DISPTIME
				BL USART_DISPTIME
NENI_TL0		
				
				TST		R6, #0x2			; sestupna hrana na tlacitku PA1 (potvrdit)
				BEQ 	NENI_TL1			; skok, pokud neni R3 & 0x2 shodne
				; je sest hrana na tl. 1:
				MOV R0, #state_available	; prepnuti do stavu "available"
				MOV 	R6, R1			; ulozeni hodnoty IDR z aktualni iterace do R6 pro pristi iteraci
				BL FLASH_WRITE			; zapsani aktualni nastavene hodnoty casu (R4) do flash
				B CONTROL
NENI_TL1
				
				TST		R6, #0x4			; sestupna hrana na tlacitku PA2 (-)
				BEQ 	NENI_TL2			; skok, pokud neni R3 & 0x2 shodne
				; je sest hrana na tl. 2:
				MOV R0, #state_setting		; prepnuti stavu automatu do "setting"
				
				; kontrola stisku obou talcitek (+/-)
				CMP R9, #0
				BEQ NEJSOU_OBE0 
				; byla stiskla obe:
				SUBS R9, #1
				BNE SKIP_TL			; uvolneno prvni z obou tlacitek -> skok
				BL RESET_TIME
				;MOV R9, #0
				B SKIP_TL
NEJSOU_OBE0 
				
				CMP R7, #BUTTON_TIME		; kontrola na delku stisku
				MOV R3, #1
				BLT DEC_1
				; dekrementace o 5:
				MOV R3, #5
DEC_1			
				;LDR R2, =TIM3_CNT
				;LDR R3, [R2]
				;SUB R3, R3, R9				; zmenseni hodnoty do counteru 0 1 (v cntr je 0-98, ale cas je 1-99)
				;STR R3, [R2]
				SUB R4, R4, R3				; snizi hodnotu v R4 (nastaveny cas) o 1
				CMP R4, #1					; porovnani s min hodnotou casu
				BGE IN_RANGE
				; vysledek odcitani je mimo rozsah (<1)
				ADD R4, R4, #99			; prepocti zpet na kladne cislo v rozsahu 1-99
IN_RANGE
				LDR R3, =TIM3_CNT
				SUB R2, R4, #1 				; zmenseni hodnoty do counteru 0 1 (v cntr je 0-98, ale cas je 1-99)
				STR R2, [R3]				; hodnota counteru upravena dle nastaveni tlacitkem
NENI_TL2

				TST		R6, #0x8			; sestupna hrana na tlacitku PA3 (+)
				BEQ 	NENI_TL3			; skok, pokud neni R6 & 0x8 shodne
				; je sest hrana na tl. 3:
				MOV R0, #state_setting		; prepnuti stavu automatu do "setting"
				
				; kontrola stisku obou talcitek (+/-)
				CMP R9, #0
				BEQ NEJSOU_OBE1 
				; byla stiskla obe:
				SUBS R9, #1
				BNE SKIP_TL			; uvolneno prvni z obou tlacitek -> skok
				BL RESET_TIME
				
				B SKIP_TL
NEJSOU_OBE1 
		
				CMP R7, #BUTTON_TIME		; kontrola na delku stisku
				MOV R3, #1
				BLT INC_1
				; inkrementace o 5:
				MOV R3, #5
INC_1			
				ADD R4, R4, R3				; zvysi hodnotu v R4 (nastaveny cas) o 1
				
				CMP R4, #100
				BLO MENSI100				; skok, pokud je vzsledek pricteni mensi nez 100
				; vysledek pricteni je vetsi nebo roven 100
				SUB R4, R4, #99				; prepocti zpet na cislo v rozsahu 1-99
MENSI100
				LDR R3, =TIM3_CNT
				SUB R2, R4, #1 				; zmenseni hodnoty do counteru 0 1 (v cntr je 0-98, ale cas je 1-99)
				STR R2, [R3]				; hodnota counteru upravena dle nastaveni tlacitkem
NENI_TL3

				TST		R6, #0x10		; sestupna hrana na tlacitku 
				BEQ 	NENI_TL4			; skok, pokud neni R3 & 0x1 shodne
				; je sest hrana na tl. 4 (enkoder)
				MOV R0, #state_available	; prepnuti do stavu "available"
				MOV 	R6, R1			; ulozeni hodnoty IDR z aktualni iterace do R6 pro pristi iteraci
				BL FLASH_WRITE			; zapsani aktualni nastavene hodnoty casu (R4) do flash
				B CONTROL
NENI_TL4		
		
				B SKIP_TL
		
		
NABEZ_HRANA
				TST 	R1, #0x1
				BEQ		NENI_TL_0
				BL LEDG_ON				; aktivace zelene LEDky
				MOV R0, #state_running  ; zmena stavu automatu na "running" 
NENI_TL_0

				TST 	R1, #0x4
				BEQ		NENI_TL_2
				MOV 	R7, #0			; nulovani SW citace
NENI_TL_2
				
				TST 	R1, #0x8
				BEQ		NENI_TL_3
				MOV 	R7, #0			; nulovani SW citace
NENI_TL_3

				;B SKIP_TL
				
			

SKIP_TL
				; citac delky stisku tlacitka
				ANDS	R2, R1, #2_1100
				;CMP 	R1, #2_1100
				BEQ		NESTISKLE
				; nastane, pokud je aspon jedno z talcitek +/- stisknuto:
				ADD R7, R7, #1			; inkrementace SW counteru
NESTISKLE
				
				MOV 	R6, R1			; ulozeni hodnoty IDR z aktualni iterace do R6 pro pristi iteraci
				; konec cteni tlacitek
				
				; cteni z enkoderu, uprava hodnoty counteru resp. hodnoty casu v R4 podle counteru Timeru3 (enkoder)
				; kontrola, nejsme ve stavu running
				;AND R2, R1, #0xF		; maska na spodni ctyri bity (piny tlacitek) 
				CMP R2, #0x0			; kontrola, zda neni stisknuto zadne tlacitko
				BNE SKIP_ENC
				; zadne tlacitko neni stiskle, vyhodnoceni enkoderu
				LDR R1, =TIM3_CNT
				LDR R2, [R1]			; hodnota counteru enkoderu do R2
				ADD R2, R2, #1			; zvetseni hodnoty counteru o 1 (chceme cas 1-99)
				
				; nacteni minule hodnoty counteru TIM3 z RAM
				LDR.W R1, =moje_RAM 	; nacteni hodnoty counteru TIM3 do RAM
				LDRB R3, [R1, #4]		; do R3 nactena hodnota counteru TIM3 do RAM
				
				CMP R3, R2				; porovnani nastaveneho casu s hodnotou v counteru enkoderu
				BEQ SKIP_ENC			; zadna zmena na encoderu
				; hodnota counteru enkoderu se zmenila:
				MOV R0, #state_setting	; prepnuti stavu automatu do "setting"
				;BL LEDB_ON
				
				; osetreni preteceni/podteceni counteru resi Timer3 
				MOV R4, R2				; hodnota counteru do R4
				
				LDR.W R1, =moje_RAM 	; ulozeni hodnoty counteru TIM3 do RAM
				STRB R2, [R1, #4]		; ulozeni hodnoty counteru TIM3 do RAM
				
				BL TO_DECADIC
				BL LCD_DISPTIME
				BL USART_DISPTIME
SKIP_ENC				
				
				
				CMP R8, #500 			; odpovida jedne sekunde, protoze delay se 1ms delay se vzkonava v kazde iteraci dvakrat
				BEQ RESET_SWCNTR
				ADD R8, R8, #1			; inkrementace SW citace
				B LOOP
RESET_SWCNTR				
				MOV R8, #0				; reset sw citace do 0
				
				CMP R10, #light_on 		; kontrola, zda jsme ve stavu "svetla sviti"
				BNE LOOP 				; pokud svetla nesviti, skok na LOOP
				
				; jsme ve stavu "svetla sviti"
				SUBS R5, #1			; pro debug, snizovani hodnoty R5, ukazuje se na displeji
				BEQ CONTROL			; automat dojel do konce, zhasnou LED, na displej defaultni hodnota, reset stavu
				BL TO_DECADIC				; spocte pro registry R4 a R5 desitky a jednotky, ulozeni do moje_RAM
				
				; zde prepsat cislo na LCD displeji
				BL LCD_DISPTIME
				BL USART_DISPTIME
				
				B LOOP
				
;***************************************************************************************************
;* Jmeno funkce		: RCC_CNF
;* Popis			: Konfigurace systemovych hodin a hodin periferii
;* Vstup			: Zadny
;* Vystup			: Zadny
;* Komentar			: Nastaveni PLL jako zdroj hodin systemu (24MHz),
;*  				  a privedeni hodin na branu C 	
;**************************************************************************************************
RCC_CNF			PROC
				LDR		R0, =RCC_CR		; Kopie adresy RCC_CR (Clock Control Register) do R0,
										; RCC_CRje v souboru INI.S			
				LDR		R1, [R0]		; Nacteni obsahu registru na adrese v R0 do R1
				BIC		R1, R1, #0x50000; Editace hodnoty v R1, tj. nulovani hodnoty, kde je '1'
										; HSE oscilator OFF (HSEON), ext.oscilator NOT BZPASSED(HSEBYP) 
				STR		R1, [R0]		; Ulozeni editovane hodnoty v R1 na adresu v R0 
 
				LDR		R1, [R0]		; Opet nacteni do R1 stav registru RCC_CR
				ORR		R1, R1, #0x10000; Maska pro zapnuti HSE	(krystalovy oscilator)	
				STR		R1, [R0]		; HSE zapnut
NO_HSE_RDY		LDR		R1, [R0]		; Nacteni do R1 stav registru RCC_CR
				TST	 	R1, #0x20000	; Test stability HSE, (R0 & 0x20000)
				BEQ 	NO_HSE_RDY		; Skok pri nestabilite, pri stabilite se pokracuje v kodu
	
				LDR		R0, =RCC_CFGR	; Nacteni adresy RCC_CFGR (Clock Configuration Register) do R0
				LDR		R1, [R0]		; Nacteni do R1 stav registru RCC_CFGR
				BIC		R1, R1, #0xF0	; Editace, SCLK nedeleno
				STR		R1, [R0]		; Ulozeni noveho stavu do RCC_CFGR 

				LDR		R1, [R0]		; Opet nacteni RCC_CFGR
				BIC		R1, R1, #0x3800	; Editace, HCLK nedeleno (PPRE2)
				STR		R1, [R0]		; Ulozeni nove hodnoty

				LDR		R1, [R0]		; Opet nacteni RCC_CFGR
				BIC		R1, R1, #0x700	; HCLK nedeleno	(PPRE1)
				ORR		R1, R1, #0x400	; Maskovani, konstanta pro HCLK/2
				STR		R1, [R0]		; Ulozeni nove hodnoty
			
				LDR		R1, [R0]		 ; Opet nacteni RCC_CFGR
				BIC		R1, R1, #0x3F0000; Nuluje PLLMUL, PLLXTPRE, PLLSRC
				LDR		R2, =0x50000	 ; Maska, PLL x3, HSE jako PLL vstup =24MHz Clk
				ORR		R1, R1, R2		 ; Maskovani, logicky soucet R1 a R2	
				STR		R1, [R0]		 ; Ulozeni nove hodnoty		 

				LDR		R0, =PLLON		; Nacteni adresy bitu PLLON do R0(ADRESA BIT BANDING)
				MOV		R1, #0x01		; Konstanta pro povoleni PLL (fazovy zaves) 
				STR		R1, [R0]		; Ulozeni nove hodnoty

				LDR		R0, =RCC_CR		; Kopie adresy  RCC_CR do R0
NO_PLL_RDY		LDR		R1, [R0]		; Nacteni stavu registru RCC_CR do R1
				TST		R1, #0x2000000	; Test spusteni PLL (test stability)
				BEQ		NO_PLL_RDY		; Skok na navesti NO_PLL_RDY pri nespustene PLL

				LDR		R0, =RCC_CFGR	; Kopie adresy RCC_CFGR do R0
				LDR		R1, [R0]		; Nacteni stavu registru RCC_CFGR do R1
				BIC		R1, R1, #0x3	; HSI jako hodiny
			;	ORR		R1, R1, #0x1	; Maskovani, HSE jako hodiny
				ORR		R1, R1, #0x2	; Maskovani, PLL jako hodiny
				STR		R1, [R0]		; PLL je zdroj hodin

				LDR		R0, =RCC_APB2ENR; Kopie adresy RCC_APB2ENR (APB2 peripheral clock enable register) do R0  
				LDR		R1, [R0]		; Nacteni stavu registru RCC_APB2ENR do R1
				LDR		R2, =0x401D		; Konstanta pro zapnuti hodin pro AFIO, PA, PB, PC, USART1
				ORR		R1, R1, R2		; Maskovani		
				STR		R1, [R0]		; Ulozeni nove hodnoty
				
				LDR		R0, =RCC_APB1ENR; Kopie adresy RCC_APB1ENR (APB1 peripheral clock enable register) do R0  
				LDR		R1, [R0]		; Nacteni stavu registru RCC_APB1ENR do R1
				LDR		R2, =0x2		; Konstanta pro zapnuti hodin pro Timer3
				ORR		R1, R1, R2		; Maskovani		
				STR		R1, [R0]		; Ulozeni nove hodnoty

				BX		LR				; Navrat z podprogramu, skok na adresu v LR
				align 4
				ENDP
;**************************************************************************************************
;* Jmeno funkce		: GPIO_CNF
;* Popis			: Konfigurace brany C
;* Vstup			: Zadny
;* Vystup			: Zadny
;* Komentar			: Nastaveni PC08 jako vystup (10MHz)	
;**************************************************************************************************
GPIO_CNF		PROC						; Navesti zacatku podprogramu
				
				LDR		R0, =GPIOC_CRL	; adresa GPIOC_CRH (Port Configuration Register High)
				;LDR		R1, [R0]		; Nacteni hodnoty z adresy v R0 do R1 
				;LDR		R2,=((Maska_k0) :OR: (Maska_k1))
				;BIC		R1, R1, R2 		; Nulovani vybranych bitu v R2 
				;LDR 	R2, =((Mode_out_pp :SHL: 0x0):OR:(Mode_out_pp :SHL: 0x4)) 		; konfigurace v do R2
				          ; vytvoreni hodnoty pro konfiguraci pinuPC8 a PC9 jako vystupy push pull.						  
				;ORR		R1, R1, R2		; maskovani, bit 8a 9 jako vystupy push-pull v modu 1 (10MHz)
				LDR		R1, =0x11111111	; nastaveni vsech pinu jako vystup push-pull, pripojeny na LCD D0-D7
				STR		R1, [R0]		; Ulozeni konfigurace PC0-PC7
				
				LDR		R0, =GPIOC_CRH	; adresa GPIOC_CRH (Port Configuration Register High)
				LDR		R1, [R0]		; Nacteni hodnoty z adresy v R0 do R1 
				LDR		R2,=((Maska_k0) :OR: (Maska_k1))
				BIC		R1, R1, R2 		; Nulovani vybranych bitu v R2 
				LDR 	R2, =((Mode_out_pp :SHL: 0x0):OR:(Mode_out_pp :SHL: 0x4)) 		; konfigurace v do R2
				          ; vytvoreni hodnoty pro konfiguraci pinuPC8 a PC9 jako vystupy push pull.						  
				ORR		R1, R1, R2		; maskovani, bit 8a 9 jako vystupy push-pull v modu 1 (10MHz)
				STR		R1, [R0]		; Ulozeni konfigurace PC8, PC9
				; konfigurace PB
				LDR		R0, =GPIOB_CRL	; adresa GPIOB_CRL (Port Configuration Register Low)
				LDR		R1, [R0]		; Nacteni hodnoty z adresy v R0 do R1 
				LDR		R2,=((Maska_k0):OR:(Maska_k1):OR:(Maska_k5) :OR: (Maska_k6) :OR: (Maska_k7))
				BIC		R1, R1, R2 		; Nulovani vybranych bitu v R2 
				LDR 	R2, =((Mode_out_pp):OR:(Mode_out_pp :SHL: 0x4):OR:(Mode_out_pp :SHL: 0x14):OR:(Mode_out_pp :SHL: 0x18):OR:(Mode_out_pp :SHL: 0x1C)) 		; konfigurace v do R2
				          ; vytvoreni hodnoty pro konfiguraci pinu PB5, PB6, PB7 jako vystupy push pull.						  
				ORR		R1, R1, R2		; maskovani, jako vystupy push-pull v modu 1 (10MHz)
				STR		R1, [R0]		; Ulozeni konfigurace
				
				LDR		R0, =GPIOB_CRH	; adresa GPIOB_CRL (Port Configuration Register High)
				LDR		R1, [R0]		; Nacteni hodnoty z adresy v R0 do R1 
				LDR		R2,=((Maska_k0) :OR: (Maska_k1))
				BIC		R1, R1, R2 		; Nulovani vybranych bitu v R2 
				LDR 	R2, =((Mode_out_pp :SHL: 0x0):OR:(Mode_out_pp :SHL: 0x4)) 		; konfigurace v do R2
				          ; vytvoreni hodnoty pro konfiguraci pinu PB8, PB9 jako vystupy push pull.						  
				ORR		R1, R1, R2		; maskovani, jako vystupy push-pull v modu 1 (10MHz)
				STR		R1, [R0]		; Ulozeni konfigurace
				; konec konf. PB
				
				; konfigurace PA
				LDR		R2, =0xFFFFF		; Konstanta pro nulovani nastaveni pinu 0,1,2,3,4
				LDR		R0, =GPIOA_CRL	; Kopie adresy GPIOA_CRL (Port Configuration Register Low)
										; do R0, GPIOA_CRL je v souboru INI.S	
				LDR		R1, [R0]		; Nacteni hodnoty z adresy v R0 do R1 
				BIC		R1, R1, R2 		; Nulovani bitu v R2 
				LDR		R2, =0x44088888	; Vlozeni konfigurace, PA0-PA3 jako vstup s pulldown, PA4 pullup (ma mit externi pullup, neni osazeny na desce enkoderu), PA6 a PA7 jako floating pro enkoder
				ORR		R1, R1, R2		; maskovani, nastveny jako push-pull vstup
				STR		R1, [R0]		; Ulozeni konfigurace
				
				LDR		R0, =GPIOA_ODR	; nastaveni pullup/pulldown
				MOV		R1, #0x10		; na pinu PA4 pullup, jinak pulldown
				STR		R1, [R0]
				
				LDR		R0, =GPIOA_CRH	 	; konfiguracni registr
				LDR		R1, [R0]	   		
				LDR		R2, =0xF0			; konstanta pro nulovani nastaveni bitu 10 (PA9)
				BIC		R1, R1, R2 			; PA9
				LDR		R2, =0xB0
				ORR		R1, R1, R2			; PA9 jako vystup alter. fce push-pull
				STR		R1, [R0]
				; konec konfigurace PA
				
				BX		LR				; Navrat z podprogramu, skok na adresu v LR
				align 4  ; zarovnani na hranici 4 Byte
				ENDP	

;**************************************************************************************************
;* Jmeno funkce		: TIMER3_CNF
;* Popis			: Konfigurace timeru 3
;* Vstup			: Zadny
;* Vystup			: Zadny
;* Komentar			: Nastaveni Timeru 3 pro enkoderovy vstup
;**************************************************************************************************
TIMER3_CNF		PROC						; Navesti zacatku podprogramu
				
				LDR 	R0, =TIM3_SMCR		; slave mode control
				MOV 	R1, #0x2			; SMS=’010’ if it is counting on TI1 edges only
				STR		R1, [R0]
				
				LDR 	R0, =TIM3_CCMR1		; 
				MOV 	R1, #0x1			; CC1S=’01’ (TIMx_CCMR1 register, TI1FP1 mapped on TI1).
				STR		R1, [R0]
				
				LDR 	R0, =TIM3_CCMR2		; 
				MOV 	R1, #0x1			; CC2S=’01’ (TIMx_CCMR2 register, TI1FP2 mapped on TI2)
				STR		R1, [R0]
				
				LDR 	R0, =TIM3_CCER		; CAPTURE/COMPARE ENABLE
				MOV 	R1, #0x0			; CC1P=’0’, and IC1F = ‘0000’ (TIMx_CCER register, TI1FP1 non-inverted, TI1FP1=TI1), CC2P=’0’, and IC2F = ‘0000’ (TIMx_CCER register, TI1FP2 non-inverted, TI1FP2=TI2)
				STR		R1, [R0]
				
				LDR		R0, =TIM3_CR1		; CONTROL 1 
				MOV		R1, #0x1			; CEN='1'
				STR		R1, [R0]	
				
				;LDR		R0, =TIM3_CNT		; counter, reset the value
				;MOV		R1, #DEFAULT_TIME	; nastaveni counteru na defaultni hodnotu casu pro automat
				;SUB		R1, R1, #1  		; hodnota zmensena o 1, protoze v cntru je 0-98, ale cas je v rozmezi 1-99
				;STR		R1, [R0]

				LDR		R0, =TIM3_ARR		; counter auto reload value
				MOV		R1, #98			; maximum hodnoty casu je 99 sec
				STR		R1, [R0]

				
				
				BX		LR				; Navrat z podprogramu, skok na adresu v LR
				align 4  ; zarovnani na hranici 4 Byte
				ENDP	

;**************************************************************************************************
;* Jmeno funkce		: FLASH_CNF
;* Popis			: Konfigurace pro zapis do pameti flash
;* Vstup			: Zadny
;* Vystup			: Zadny
;* Komentar			: -
;**************************************************************************************************
FLASH_CNF		PROC						; Navesti zacatku podprogramu
				
				PUSH	{LR}
				
				; unlockne FLASH
				LDR R0, =FLASH_KEYR
				LDR R1, =FLASH_KEY1
				STR R1,[R0]
				LDR R1, =FLASH_KEY2
				STR R1,[R0]
				
				BL FLASH_WAITBUSY			;cekej, dokud je flash busy
			
				BL FLASH_IDX
				
				POP 	{PC}				; Navrat z podprogramu, skok na adresu v LR
				align 4  ; zarovnani na hranici 4 Byte
				ENDP

;**************************************************************************************************
;* Jmeno funkce		: FLASH_IDX
;* Popis			: iterace pres stranku pameti flash, vrati prvni adresu s hodnotou 0xFFFF
;* Vstup			: Zadny
;* Vystup			: Zadny, zapise adresu do pameti RAM
;* Komentar			: -
;**************************************************************************************************
FLASH_IDX		PROC						; Navesti zacatku podprogramu
				PUSH	{R0, R1, R2, R3, LR}
				
				LDR R0, =flash_page
				LDR R2, =flashidx_max
				LDR R3, =0xFFFF
FLASH_SMYCKA
				LDRH R1, [R0], #2 			; inkrementace po halfwordu
				CMP R0, R2
				BGE SKIP_TOERASE 
				CMP R1, R3
				BNE FLASH_SMYCKA

				; zapis prvni neobsazene adresy do RAM
				SUBS R0, R0, #2
				LDR.W R1, =flashidx_RAM ;
				STR R0, [R1]
				B SKIP_TOEND

SKIP_TOERASE 
				
				BL FLASH_ERASE
SKIP_TOEND
				POP 	{R0, R1, R2, R3, PC}				; Navrat z podprogramu, skok na adresu v LR
				align 4  ; zarovnani na hranici 4 Byte
				ENDP

;**************************************************************************************************
;* Jmeno funkce		: FLASH_WRITE
;* Popis			: zapis nastaveneho casu do flash 
;* Vstup			: R4
;* Vystup			: Zadny
;* Komentar			: cas je od 0 do 99, ale do flash zapisujeme po halfwordech
;**************************************************************************************************
FLASH_WRITE		PROC						; Navesti zacatku podprogramu
				PUSH	{R0, R1, R2, LR}
				
				; Check that no main Flash memory operation is ongoing by checking the BSY bit in the FLASH_SR register
				BL FLASH_WAITBUSY
				;Set the PG bit in the FLASH_CR register.
				LDR     R0, =FLASH_CR
				LDR     R1, [R0]
				ORR     R1, R1, #0x1             ;Set PG bit
				STR     R1, [R0]
				;Perform the data write (half-word) at the desired address.
				LDR R0, =flashidx_RAM
				LDR R1, [R0]	
				;SUBS R1, R1, #2
				STRH R4, [R1], #2 		;inkrementace adresy v R1 o 2

				; Wait for the BSY bit to be reset.
				BL FLASH_WAITBUSY
				
				; Read the programmed value and verify.
				; TODO

				STR R1, [R0] 			; ulozeni flash idx do RAM
				
				LDR R2, =flashidx_max
				CMP R1, R2
				BLE SKIP_ERASING
				BL FLASH_ERASE
SKIP_ERASING

				POP 	{R0, R1, R2, PC}				; Navrat z podprogramu, skok na adresu v LR
				align 4  ; zarovnani na hranici 4 Byte
				ENDP

;**************************************************************************************************
;* Jmeno funkce		: FLASH_LOADTIME
;* Popis			: nacteni casu dle hodnoty ulozene ve flash
;* Vstup			: adresa v flashidx_RAM
;* Vystup			: R4, zustane v nem hodnota vyctena z flash
;* Komentar			: cas je od 0 do 99, ale do flash zapisujeme po halfwordech
;**************************************************************************************************
FLASH_LOADTIME	PROC						; Navesti zacatku podprogramu
				PUSH	{R0, R1, LR}
				
				LDR R0, =flashidx_RAM
				LDR R1, [R0]
				SUBS R1, R1, #2			; chceme predchozi hodnotu
				LDRH R4, [R1]		; do R2 se zapise hodnota z FLASH
				
				LDR R1, =0xFFFF
				CMP R4, R1
				BNE TIME_LOADED
				; cas se nenacetl spravne:
				MOV R4, #DEFAULT_TIME
TIME_LOADED
				LDR		R0, =TIM3_CNT		; counter, reset the value
				MOV		R1, R4	; nastaveni counteru na defaultni hodnotu casu pro automat
				SUB		R1, R1, #1  		; hodnota zmensena o 1, protoze v cntru je 0-98, ale cas je v rozmezi 1-99
				STR		R1, [R0]
				
				LDR.W R1, =moje_RAM 	; ulozeni hodnoty counteru TIM3 do RAM
				STRB R4, [R1, #4]		; ulozeni hodnoty counteru TIM3 do RAM
				
				POP 	{R0, R1, PC}				; Navrat z podprogramu, skok na adresu v LR
				align 4  ; zarovnani na hranici 4 Byte
				ENDP

;**************************************************************************************************
;* Jmeno funkce		: FLASH_ERASE
;* Popis			: smaze stranku flash definovanou v konstantach (posledni stranka)
;* Vstup			: Zadny
;* Vystup			: Zadny
;* Komentar			: -
;**************************************************************************************************
FLASH_ERASE		PROC						; Navesti zacatku podprogramu
				PUSH	{LR}
				
				BL FLASH_WAITBUSY
				;Set the PER bit in the FLASH_CR register
				LDR R0, =FLASH_CR
				LDR R1, [R0]
				ORR R1, R1, #2_10
				STR R1, [R0]
				; Program the FLASH_AR register to select a page to erase
				LDR R0, =FLASH_AR
				LDR R1, =flash_page
				STR R1, [R0]
				; Set the STRT bit in the FLASH_CR register
				LDR R0, =FLASH_CR
				LDR R1, [R0]
				ORR R1, #(1<<6)
				STR R1, [R0]
				
				BL FLASH_WAITBUSY
				
				; clear PER bit
				LDR R0, =FLASH_CR
				LDR R1, [R0]
				BIC R1, R1, #2          ; PER = 0
				STR R1, [R0]
				
				;Read the erased page and verify (TODO)
				
				; nastav ukazatel na flash na spravnou hodnotu
				LDR R0, =flash_page
				LDR.W R1, =flashidx_RAM 
				STR R0, [R1]
				
				POP 	{PC}				; Navrat z podprogramu, skok na adresu v LR
				align 4  ; zarovnani na hranici 4 Byte
				ENDP					

;**************************************************************************************************
;* Jmeno funkce		: FLASH_WAITBUSY
;* Popis			: cekani, dokud neni shozen bit BSY v Flash status register
;* Vstup			: Zadny
;* Vystup			: Zadny
;* Komentar			: -
;**************************************************************************************************
FLASH_WAITBUSY	PROC						; Navesti zacatku podprogramu
				PUSH	{R0,R1,LR}
WAIT_BUSY
				LDR     R0, =FLASH_SR
				LDR     R1, [R0]
				TST     R1, #0x1                 ;kontrola BSY bitu ve Flash status register
				BNE     WAIT_BUSY
				
				POP 	{R0, R1,PC}				; Navrat z podprogramu, skok na adresu v LR
				align 4  ; zarovnani na hranici 4 Byte
				ENDP

;*********************************************************************************************
;* Jmeno funkce		: USART_CNF
;* Popis			: Konfigurace USART1 pro prijem i vysilani
;* Vstup			: Zadny
;* Vystup			: Zadny
;* Komentar			: Nastaveni USART1 s prenosovou rychlosti 9600Bd
;*					 (1 start bit, 8 data bit , 1 stop bit) 	
;*********************************************************************************************					
USART_CNF		PROC
				PUSH	{LR}

				LDR		R0, =USART_BRR	   ; BAUD RATE registr
				LDR		R1, =0x009C4	   ; RATE 9600Bd (156.25 PRO 24MHz), 156 = 0x9C0, 0,25 = 0x4 
				STR		R1, [R0]

				LDR		R0, =USART_CR1	   ; control registr
				LDR		R1, [R0]
				LDR		R2, =0x200C	   	   ; USART povolen (UE = 1), vysilani i prijem povoleno (TE = 1),RE = 1
				ORR		R1, R1, R2 
				STR		R1, [R0]
				
				POP		{PC}
				align 4  ; zarovnani na hranici 4 Byte
				ENDP	

;**************************************************************************************************
;* Jmeno funkce		: LCD_INIT
;* Popis			: pocatecni nastaveni modu LCD 
;* Vstup			: Zadny
;* Vystup			: Zadny
;* Komentar			: zapojeni: RS - PB0, E - PB1
;**************************************************************************************************
LCD_INIT		PROC		  			; Navesti zacatku podprogramu + informace pro prekladac ( PROC)
				PUSH	{R0, R1, R2, LR}				; Ulozeni hodnoty navratove adresy - LR do zasobniku 
				
				MOV R3, #DOBA			; cca 500 ms
				BL DELAY				; cekani, nez nabehne LCD displej
				
				; nastaveni funkce displeje
				MOV R3, #0x38
				BL LCD_SENDINST
				
				; nastaveni modu displeje
				MOV R3, #0xC
				BL LCD_SENDINST
				
				; nastaveni modu vstupu dat
				MOV R3, #0x6
				BL LCD_SENDINST
				
				; return home (kurzor)
				MOV R3, #0x4
				BL LCD_SENDINST
				
				MOV R3, #DOBA_2MS			; cekani, nez se vykona instrukce
				BL DELAY
				
				; clear display
				MOV R3, #0x1
				BL LCD_SENDINST
				
				MOV R3, #DOBA_2MS			; cekani, nez se vykona instrukce
				BL DELAY
				
				; zapis textu na displej
				;LDR.W R3, =hlaseni_ready
				;BL LCD_SENDTEXT
				
				; zapis cisla???
				;MOV R5, R4				; SW counter, odcitani od nastavene konstanty v R4, navrat na pocatecni hodnotu
				;BL TO_DECADIC				; spocte pro registry R4 a R5 desitky a jednotky, ulozeni do moje_RAM
				
				;MOV R2, #0				; R3 urcuje misto v pameti ze ktereho se cte cislice
				;LDR.W R1, =moje_RAM		; nacteni adresz mojeRAM do R1
				;LDRB R3, [R1,R2]		; nacteni bytu z pameti moje_RAM+R3 do R0, jde o cislici (desitky/jednotky)
 				;ADD R3, R3, #0x30 ; prepocet na ASCII hodnotu
				;BL LCD_SENDCHAR
				
				;MOV R2, #2				; R3 urcuje misto v pameti ze ktereho se cte cislice
				;LDR.W R1, =moje_RAM		; nacteni adresz mojeRAM do R1
				;LDRB R3, [R1,R2]		; nacteni bytu z pameti moje_RAM+R3 do R0, jde o cislici (desitky/jednotky)
 				;ADD R3, R3, #0x30 ; prepocet na ASCII hodnotu
				;BL LCD_SENDCHAR
				
				; set cursor to the begining of 2nd line
				MOV R3, #0xC0		; 0x80 by byl zacatek prvniho radku
				BL LCD_SENDINST
				
				; zapis textu na displej
				LDR.W R3, =hlaseni_name
				BL LCD_SENDTEXT
				
				; Navrat z podprogramu, obnoveni hodnoty LR ze zasobniku
				
				POP		{R0, R1, R2, PC}		; jednodussi varianta POP misto predchozich dvou radku
				LTORG
;**************************************************************************************************
				align 4  ; zarovnani na hranici 4 Byte
				ENDP ; informace pro prekladac konec procedury, funguje to i bez PROC a ENDP


;**************************************************************************************************
;* Jmeno funkce		: LCD_SENDCHAR
;* Popis			: zobrazeni daneho znaku na LCD displeji. 
;* Vstup			: R3 = znak k zobrazeni
;* Vystup			: Zadny
;* Komentar			: TODO
;**************************************************************************************************
LCD_SENDCHAR		PROC		  			; Navesti zacatku podprogramu + informace pro prekladac ( PROC)
				PUSH	{R0, R2, LR}				; Ulozeni hodnoty navratove adresy - LR do zasobniku 
				
				; zapis znaku na displej
				LDR R2, =GPIOB_BSRR
				LDR R1, =GPIO_BSRR_BS_0
				STR R1, [R2]			; nastaveni pinu RS displeje pro zapis dat
				
				PUSH {R3}				; mozna zbytecne?
				MOV R3, #0x2
				BL DELAY				; cekani, displej vyzaduje spravny timing
				POP {R3}
				
				LDR R1, =GPIO_BSRR_BS_1
				STR R1, [R2]			; 1 na pinu E displeje pro pozdejsi zapis dat do pameti displeje
				
				BL LOADSH				; zapis dat pro LCD na shift register
				
				MOV R3, #0x4
				BL DELAY				; cekani, displej vyzaduje spravny timing
				
				LDR R2, =GPIOB_BSRR
				LDR R1, =GPIO_BSRR_BR_1
				STR R1, [R2] ; 0 na pinu E displeje pro zapis dat do pameti displeje
				
				MOV R3, #0x190			; cekani 50 us, instrukce trva dle datasheetu 37us
				BL DELAY				; cekani, displej vyzaduje spravny timing
				
				; Navrat z podprogramu, obnoveni hodnoty LR ze zasobniku
				
				POP		{R0, R2, PC}		; jednodussi varianta POP misto predchozich dvou radku
				LTORG
;**************************************************************************************************
				align 4  ; zarovnani na hranici 4 Byte
				ENDP ; informace pro prekladac konec procedury, funguje to i bez PROC a ENDP

;**************************************************************************************************
;* Jmeno funkce		: LCD_SENDINST
;* Popis			: zobrazeni daneho znaku na LCD displeji. 
;* Vstup			: R3 = instrukce k zapsani
;* Vystup			: Zadny
;* Komentar			: TODO
;**************************************************************************************************
LCD_SENDINST	PROC		  			; Navesti zacatku podprogramu + informace pro prekladac ( PROC)
				PUSH	{R0, R2, LR}				; Ulozeni hodnoty navratove adresy - LR do zasobniku 
				;PUSH	{R0} ; R1 ulozeni, ,
				
				
				; zapis znaku na displej
				LDR R2, =GPIOB_BSRR
				LDR R1, =GPIO_BSRR_BR_0
				STR R1, [R2]			; nastaveni pinu RS displeje pro zapis dat
				
				PUSH {R3}				; mozna zbytecne?
				MOV R3, #0x2
				BL DELAY				; cekani, displej vyzaduje spravny timing
				POP {R3}
				
				LDR R1, =GPIO_BSRR_BS_1
				STR R1, [R2]			; 1 na pinu E displeje pro pozdejsi zapis dat do pameti displeje
				
				BL LOADSH				; zapis dat pro LCD na shift register
				
				MOV R3, #0x4
				BL DELAY				; cekani, displej vyzaduje spravny timing
				
				LDR R2, =GPIOB_BSRR
				LDR R1, =GPIO_BSRR_BR_1
				STR R1, [R2] ; 0 na pinu E displeje pro zapis dat do pameti displeje
				
				MOV R3, #0x190			; cekani 50 us, instrukce trva dle datasheetu 37us
				BL DELAY				; cekani, displej vyzaduje spravny timing
				
				; Navrat z podprogramu, obnoveni hodnoty LR ze zasobniku
				POP		{R0, R2, PC}		; jednodussi varianta POP misto predchozich dvou radku
				;LTORG
;**************************************************************************************************
				align 4  ; zarovnani na hranici 4 Byte
				ENDP ; informace pro prekladac konec procedury, funguje to i bez PROC a ENDP

;**************************************************************************************************
;* Jmeno funkce		: LCD_SENDTEXT
;* Popis			: zobrazeni textu ulozeneho v pameti na adrese dle R3 na LCD displeji. 
;* Vstup			: R3 = adresa textu k zapsani
;* Vystup			: Zadny
;* Komentar			: TODO
;**************************************************************************************************
LCD_SENDTEXT	PROC		  			; Navesti zacatku podprogramu + informace pro prekladac ( PROC)
				PUSH	{R0, R2, LR}				; Ulozeni hodnoty navratove adresy - LR do zasobniku 
				
				MOV R2, R3
NACTI_ZNAK				
				LDRB R3, [R2], #1
				CMP R3, #0x0
				BEQ KONEC_CTENI
				; znak neni 0, chceme ho vypsat
				BL LCD_SENDCHAR
				B NACTI_ZNAK
KONEC_CTENI
				
				POP		{R0, R2, PC}		; jednodussi varianta POP misto predchozich dvou radku
;**************************************************************************************************
				align 4  ; zarovnani na hranici 4 Byte
				ENDP ; informace pro prekladac konec procedury, funguje to i bez PROC a ENDP
					
;**************************************************************************************************
;* Jmeno funkce		: LCD_DISPTIME
;* Popis			: zobrazeni cisla (casu) ulozeneho dle RAM na LCD displeji. 
;* Vstup			: R0 = stav, podle nej se voli cislo k vypisu
;* Vystup			: Zadny
;* Komentar			: nacti polohu kurzoru, prepis cislo, vrat kurzor zpatky -> NE, hardcode na polohu kurzoru na zacatku fce
;**************************************************************************************************
LCD_DISPTIME	PROC		  			; Navesti zacatku podprogramu + informace pro prekladac ( PROC)
				PUSH	{R2, LR}				; Ulozeni hodnoty navratove adresy - LR do zasobniku 
				
				; LCD displej (TODO - prepisovat jen, pokud je to nutne, urcite ne v kazde iteraci)
				; stav available nastavit na LCD pouze v control
				MOV R3, #0x80		; 0x80 by byl zacatek prvniho radku
				BL LCD_SENDINST
				
				CMP R0, #state_running
				BNE LCD_SKIP0
				; je ve stavu running
				
				; zapis textu na displej
				LDR.W R3, =hlaseni_run
				BL LCD_SENDTEXT
				
				LDR.W R1, =moje_RAM		; nacteni adresy mojeRAM do R1
				LDRB R3, [R1,#1]		; nacteni bytu z pameti moje_RAM+0 do R3, jde o cislici (desitky/jednotky)
				BL LCD_DISPNUM
				LDR.W R1, =moje_RAM		; nacteni adresz mojeRAM do R1
				LDRB R3, [R1,#3]		; nacteni bytu z pameti moje_RAM+2 do R0, jde o cislici (desitky/jednotky)
				BL LCD_DISPNUM
				
LCD_SKIP0
				CMP R0, #state_setting
				BNE LCD_SKIP1
				; je ve stavu setting
				MOV R3, #0x80		; 0x80 by byl zacatek prvniho radku
				BL LCD_SENDINST
				
				; zapis textu na displej
				LDR.W R3, =hlaseni_set
				BL LCD_SENDTEXT
				
				LDR.W R1, =moje_RAM		; nacteni adresz mojeRAM do R1
				LDRB R3, [R1,#0]		; nacteni bytu z pameti moje_RAM+1 do R3, jde o cislici (desitky/jednotky)
				BL LCD_DISPNUM
				LDR.W R1, =moje_RAM		; nacteni adresz mojeRAM do R1
				LDRB R3, [R1,#2]		; nacteni bytu z pameti moje_RAM+3 do R3, jde o cislici (desitky/jednotky)
				BL LCD_DISPNUM
LCD_SKIP1
				
				CMP R0, #state_available
				BNE LCD_SKIP2
				; je ve stavu ready (available)
				; zapis textu na displej
				LDR.W R3, =hlaseni_ready
				BL LCD_SENDTEXT
				
				LDR.W R1, =moje_RAM		; nacteni adresz mojeRAM do R1
				LDRB R3, [R1,#1]		; nacteni bytu z pameti moje_RAM+1 do R3, jde o cislici (desitky/jednotky)
				BL LCD_DISPNUM
				LDR.W R1, =moje_RAM		; nacteni adresz mojeRAM do R1
				LDRB R3, [R1,#3]		; nacteni bytu z pameti moje_RAM+3 do R3, jde o cislici (desitky/jednotky)
				BL LCD_DISPNUM
LCD_SKIP2
				; doplnit mezerami 
				LDR.W R3, =hlaseni_clear
				BL LCD_SENDTEXT
				
				
				POP		{R2, PC}		; jednodussi varianta POP misto predchozich dvou radku
;**************************************************************************************************
				align 4  ; zarovnani na hranici 4 Byte
				ENDP ; informace pro prekladac konec procedury, funguje to i bez PROC a ENDP


;**************************************************************************************************
;* Jmeno funkce		: LCD_DISPNUM
;* Popis			: zobrazeni dane cifry na LCD displeji. 
;* Vstup			: R3 = cifra, ktera se ma zobrazit. celkem jsou ctyri cifry, jsou ulozeny v pameti moje_RAM [0-3]
;* Vystup			: Zadny
;* Komentar			: TODO
;**************************************************************************************************
LCD_DISPNUM		PROC		  			; Navesti zacatku podprogramu + informace pro prekladac ( PROC)
				PUSH	{LR}				; Ulozeni hodnoty navratove adresy - LR do zasobniku 
				
				;ORR R3, R3, #(2_11<<4)	; prevod cisla na ASCII znak
				BL LCD_SENDCHAR			; odeslani znaku na LCD
				
				; Navrat z podprogramu, obnoveni hodnoty LR ze zasobniku
				POP		{PC}			; jednodussi varianta POP misto predchozich dvou radku
;**************************************************************************************************
				align 4  ; zarovnani na hranici 4 Byte
				ENDP ; informace pro prekladac konec procedury, funguje to i bez PROC a ENDP


;**************************************************************************************************
;* Jmeno funkce		: LOADSH
;* Popis			: Naplneni posuvneho registru daty ( -> 8b dat) pro LCD 
;* Vstup			: R3 = bitova posloupnost urcena k vyslani na shift register
;* Vystup			: Zadny
;* Komentar			: TODO
;**************************************************************************************************
LOADSH 			PROC		  			; Navesti zacatku podprogramu + informace pro prekladac ( PROC)
				PUSH	{LR}				; Ulozeni hodnoty navratove adresy - LR do zasobniku 
				PUSH	{R1} ; R1 ulozeni, ,
				
				; priprav data pro zapis do shift registru do registru, pozor na poradi bitu(opacne)
				
				ORR R3, R3, # 0x100 	; pridani 1 na pozici 8. bitu v R0
REPEAT			
				; cyklus
				LSRS 	R3,R3, #1 		; bit posun R0 o jedna doprava
				BEQ		SHIFT_FINISHED			; opakovani smycky pri nenulovosti R3 (skok dle priznaku Z)
				; telo cyklu
				BCS VYSLI_1
				; vysli 0
				LDR 	R2, =GPIOB_BSRR 
				LDR		R1, =GPIO_BSRR_BR_6
				STR		R1, [R2]		; Zapis hodnoty v R1 na adresu v R2, nastavena "data" na 0
				B VYSLANO
				
VYSLI_1
				; vysli 1
				LDR 	R2, =GPIOB_BSRR 
				LDR		R1, =GPIO_BSRR_BS_6
				STR		R1, [R2]		; Zapis hodnoty v R1 na adresu v R2, nastavena "data" na 1.
				
VYSLANO
				
				;LDR 	R2, =GPIOC_BSRR 
				LDR		R1, =GPIO_BSRR_BS_7
				STR		R1, [R2]		; Zapis hodnoty v R1 na adresu v R2, nastaveni "clock" na 1
				
				;LDR 	R2, =GPIOC_BSRR 
				LDR		R1, =GPIO_BSRR_BR_7
				STR		R1, [R2]		; Zapis hodnoty v R1 na adresu v R2, nastaveni "clock" na 0

				
				B REPEAT
SHIFT_FINISHED
			
				; Navrat z podprogramu, obnoveni hodnoty LR ze zasobniku
				POP		{R1}  ; obnoveni R1 ze zasobniku
				POP		{PC}		; jednodussi varianta POP misto predchozich dvou radku
;**************************************************************************************************
				align 4  ; zarovnani na hranici 4 Byte
				ENDP ; informace pro prekladac konec procedury, funguje to i bez PROC a ENDP


;**************************************************************************************************
;* Jmeno funkce		: DISPLAY_NUM
;* Popis			: zobrazeni dane cifry na displeji. 
;* Vstup			: R3 = cifra, ktera se ma zobrazit. celkem jsou ctyri cifry, jsou ulozeny v pameti moje_RAM [0-3]
;* Vystup			: Zadny
;* Komentar			: TODO
;**************************************************************************************************
DISPLAY_NUM		PROC		  			; Navesti zacatku podprogramu + informace pro prekladac ( PROC)
				PUSH	{R0, R3, LR}				; Ulozeni hodnoty navratove adresy - LR do zasobniku 
				;PUSH	{R0} ; R1 ulozeni,
				
				LDR.W R2, =gener_zn 	; R2 ukazuje na zacátek generatoru znaku
				LDR.W R1, =moje_RAM		; nacteni adresz mojeRAM do R1
				LDRB R0, [R1,R3]		; nacteni bytu z pameti moje_RAM+R3 do R0, jde o cislici (desitky/jednotky)
 				ADDS R2, R2, R0 		;pricteni posunu o hodnotu cislice , zde dle hodnoty v R3
				LDRB R3, [R2] 			;nacteni znaku z generatoru jako bajt, horni 3 bajty v R3 jsou 0
				
				BL LOADSH
			
				; Navrat z podprogramu, obnoveni hodnoty LR ze zasobniku
				;POP		{R0}  ; obnoveni R1 ze zasobniku
				POP		{R0, R3, PC}		; jednodussi varianta POP misto predchozich dvou radku
;**************************************************************************************************
				align 4  ; zarovnani na hranici 4 Byte
				ENDP ; informace pro prekladac konec procedury, funguje to i bez PROC a ENDP


;**************************************************************************************************
;* Jmeno funkce		: TO_DECADIC
;* Popis			: vrati R4/10 celociselne a zbytek
;* Vstup			: R4, R5 = hodnota (cas) dana uzivatelem, nastaveny cas (konstantni) a aktualni (snizujici se) cas
;* Vystup			: cifra pro desitky, cifra pro jednotky, ulozeno do moje_RAM
;* Komentar			: uklada jako ASCII znak (ne jako cislo)
;**************************************************************************************************
TO_DECADIC		PROC		  			; Navesti zacatku podprogramu + informace pro prekladac ( PROC)
				
				PUSH	{R3, R4, R5, LR} 			; ulozeni R5
				; prvni iterace, R4
				MOV		R3, #0  		; Vlozeni konstanty 0 do R3, citani iteraci (desitky), v R4 jednotky
				
				CMP R4, #10
				BLT PRESKOC_SMYCKU
				
SMYCKA			SUB	R4, R4, #10		; Odecteni 10 od R4,tj. R4 = R4 - 10 a nastaveni priznakoveho registru   	
				ADD R3, R3, #1		; inkrementace pocitadla iteraci
				CMP R4, #10			; porovnani R4 vs hodnota 10
				BGE	SMYCKA			; Skok na navesti pri R3 >= 10 (skok dle priznaku)
				
PRESKOC_SMYCKU
				
				LDR.W R2, =moje_RAM ;
				ORR 	R3, R3, #(2_11<<4)	; prevod cisla na ASCII znak
				ORR 	R4, R4, #(2_11<<4)	; prevod cisla na ASCII znak
				STRB 	R3, [R2]
				STRB 	R4, [R2, #2]
				
				; druha iterace, R5
				MOV		R3, #0  		; Vlozeni konstanty 0 do R3, citani iteraci (desitky), v R4 jednotky
				CMP 	R5, #10
				BLT PRESKOC_SMYCKU1
				
SMYCKA1			SUB		R5, R5, #10		; Odecteni 10 od R4,tj. R4 = R4 - 10 a nastaveni priznakoveho registru   	
				ADD 	R3, R3, #1		; inkrementace pocitadla iteraci
				CMP 	R5, #10			; porovnani R4 vs hodnota 10
				BGE	SMYCKA1			; Skok na navesti pri R3 >= 10 (skok dle priznaku)
				
PRESKOC_SMYCKU1
				
				;LDR.W 	R2, =moje_RAM ;
				ORR 	R3, R3, #(2_11<<4)	; prevod cisla na ASCII znak
				ORR 	R5, R5, #(2_11<<4)	; prevod cisla na ASCII znak
				STRB 	R3, [R2, #1]
				STRB 	R5, [R2, #3]
				
				POP	{R3, R4, R5, PC} 			; ulozeni R5
;**************************************************************************************************
				align 4  ; zarovnani na hranici 4 Byte
				ENDP ; informace pro prekladac konec procedury, funguje to i bez PROC a ENDP


;**************************************************************************************************
;* Jmeno funkce		: LEDG_ON
;* Popis			: rosviti zelenou LED
;* Vstup			: zadny
;* Vystup			: Zadny
;* Komentar			: -
;**************************************************************************************************
LEDG_ON			PROC		  			; Navesti zacatku podprogramu + informace pro prekladac ( PROC)
				PUSH	{LR}				; Ulozeni hodnoty navratove adresy - LR do zasobniku 
				PUSH	{R0}
				
				LDR		R2, =GPIOC_BSRR	; adresa registru GPIOC_BSRR R2, GPIOC_BSRR je v souboru INI.S				
				LDR		R1, [R2]
				LDR		R0,  =(GPIO_BSRR_BS_9)
				ORR		R1, R1, R0
				STR		R1, [R2]						; 
				
				POP		{R0}
				POP		{PC}		; jednodussi varianta POP misto predchozich dvou radku
;**************************************************************************************************
				align 4  ; zarovnani na hranici 4 Byte
				ENDP ; informace pro prekladac konec procedury, funguje to i bez PROC a ENDP


;**************************************************************************************************
;* Jmeno funkce		: LEDB_ON
;* Popis			: rosviti modrou LED
;* Vstup			: zadny
;* Vystup			: Zadny
;* Komentar			: rozviceni modre LED se zachovanim stavu zelene LED
;**************************************************************************************************
LEDB_ON			PROC		  			; Navesti zacatku podprogramu + informace pro prekladac ( PROC)
				PUSH	{LR}				; Ulozeni hodnoty navratove adresy - LR do zasobniku 
				PUSH	{R0}
				
				LDR		R2, =GPIOC_BSRR	; adresa registru GPIOC_BSRR R2, GPIOC_BSRR je v souboru INI.S				
				LDR		R1, [R2]
				LDR		R0,  =(GPIO_BSRR_BS_8)
				ORR		R1, R1, R0
				STR		R1, [R2]						; 
				
				POP		{R0}
				POP		{PC}		; jednodussi varianta POP misto predchozich dvou radku
;**************************************************************************************************
				align 4  ; zarovnani na hranici 4 Byte
				ENDP ; informace pro prekladac konec procedury, funguje to i bez PROC a ENDP


;**************************************************************************************************
;* Jmeno funkce		: LEDB_OFF
;* Popis			: zhasni modrou LED
;* Vstup			: zadny
;* Vystup			: Zadny
;* Komentar			: zhasnuti modre LED se zachovanim stavu zelene LED
;**************************************************************************************************
LEDB_OFF		PROC		  			; Navesti zacatku podprogramu + informace pro prekladac ( PROC)
				PUSH	{LR}				; Ulozeni hodnoty navratove adresy - LR do zasobniku 
				PUSH	{R0}
				
				LDR		R2, =GPIOC_BSRR	; adresa registru GPIOC_BSRR R2, GPIOC_BSRR je v souboru INI.S				
				LDR		R1, [R2]
				LDR		R0,  =(GPIO_BSRR_BR_8)
				ORR		R1, R1, R0
				STR		R1, [R2]						; 
				
				POP		{R0}
				POP		{PC}		; jednodussi varianta POP misto predchozich dvou radku
;**************************************************************************************************
				align 4  ; zarovnani na hranici 4 Byte
				ENDP ; informace pro prekladac konec procedury, funguje to i bez PROC a ENDP


;**************************************************************************************************
;* Jmeno funkce		: LEDG_OFF
;* Popis			: zhasni zelenou LED
;* Vstup			: zadny
;* Vystup			: Zadny
;* Komentar			: zhasnuti zelene LED se zachovanim stavu zelene LED
;**************************************************************************************************
LEDG_OFF		PROC		  			; Navesti zacatku podprogramu + informace pro prekladac ( PROC)
				PUSH	{LR}				; Ulozeni hodnoty navratove adresy - LR do zasobniku 
				PUSH	{R0}
				
				LDR		R2, =GPIOC_BSRR	; adresa registru GPIOC_BSRR R2, GPIOC_BSRR je v souboru INI.S				
				LDR		R1, [R2]
				LDR		R0,  =(GPIO_BSRR_BR_9)
				ORR		R1, R1, R0
				STR		R1, [R2]						; 
				
				POP		{R0}
				POP		{PC}		; jednodussi varianta POP misto predchozich dvou radku
;**************************************************************************************************
				align 4  ; zarovnani na hranici 4 Byte
				ENDP ; informace pro prekladac konec procedury, funguje to i bez PROC a ENDP
										
;**************************************************************************************************
;* Jmeno funkce		: RESET_TIME
;* Popis			: resetuj ulozenou hodnotu casu na defaultni
;* Vstup			: zadny
;* Vystup			: Zadny
;* Komentar			: -
;**************************************************************************************************
RESET_TIME		PROC		  			; Navesti zacatku podprogramu + informace pro prekladac ( PROC)
				PUSH	{R1, R2, LR}				; Ulozeni hodnoty navratove adresy - LR do zasobniku 
				
				MOV R4, #DEFAULT_TIME 	; reset nastavovane hodnoty casu
				MOV R5, #DEFAULT_TIME 	; reset nastavovane hodnoty casu
				LDR R1, =TIM3_CNT
				SUB R2, R4, #1
				STR R2, [R1]
				BL TO_DECADIC
				BL LCD_DISPTIME
				BL USART_DISPTIME
				
				POP		{R1, R2, PC}		; jednodussi varianta POP misto predchozich dvou radku
;**************************************************************************************************
				align 4  ; zarovnani na hranici 4 Byte
				ENDP ; informace pro prekladac konec procedury, funguje to i bez PROC a ENDP					

;*********************************************************************************************
;* Jmeno funkce		: REC_USATR
;* Popis			: Podprogram pro prijem dat z USART
;* Vstup			: Zadny
;* Vystup			: zadny
;* Komentar			: Je prijat jeden bajt pomoci USART1, neblokujici, vyuzito pro polling	
;*********************************************************************************************
REC_USART		PROC		  			; Navesti zacatku podprogramu + informace pro prekladac ( PROC)
				PUSH	{R1, R2, R3, LR}	 		 

				LDR 	R1, =USART_SR
				LDR 	R2,[R1] 		
				TST 	R2, #0x20 			; test naplneni cteciho bufferu
				BEQ 	NO_RDY_REC 			; skok pri nenaplnenem bufferu
				LDR 	R1, =USART_DR 	
				LDR		R3,	[R1]			; precteny bajt v RO
				
				; vyhodnoceni prijateho bajtu:
				CMP R3, #0x2B ; znak "+"
				BNE SKIP_UART_0
				; prijat znak "+":
				ADD R4, R4, #1				; zvetseni nastavovaneho casu o 1
				CMP R4, #100
				BLO MENSI100_UART				; skok, pokud je vzsledek pricteni mensi nez 100
				; vysledek pricteni je vetsi nebo roven 100
				SUB R4, R4, #99				; prepocti zpet na cislo v rozsahu 1-99
MENSI100_UART
				LDR R1, =TIM3_CNT
				SUB R2, R4, #1 				; zmenseni hodnoty do counteru o 1 (v cntr je 0-98, ale cas je 1-99)
				STR R2, [R1]				; hodnota counteru upravena dle nastaveni tlacitkem
				MOV R0, #state_setting		; prepnuti do stavu "setting"
SKIP_UART_0				
				
				CMP R3, #0x2D ; znak "-"
				BNE SKIP_UART_1
				; prijat znak "-":
				SUB R4, R4, #1
				CMP R4, #1					; porovnani s min moznou hodnotou casu (1)
				BGE IN_RANGE_UART
				; vysledek odcitani je mimo rozsah (<1)
				ADD R4, R4, #99			; prepocti zpet na kladne cislo v rozsahu 1-99
IN_RANGE_UART
				LDR R1, =TIM3_CNT
				SUB R2, R4, #1 				; zmenseni hodnoty do counteru 0 1 (v cntr je 0-98, ale cas je 1-99)
				STR R2, [R1]				; hodnota counteru upravena dle nastaveni tlacitkem
				MOV R0, #state_setting		; prepnuti do stavu "setting"
SKIP_UART_1		
				
				CMP R3, #0x20 ; znak "[space]"
				BNE SKIP_UART_2
				MOV R0, #state_available	; prepnuti do stavu "available"
				BL FLASH_WRITE
				B CONTROL
				
SKIP_UART_2

				CMP R3, #0x73 ; znak "s"
				BNE SKIP_UART_3
				MOV R0, #state_running	; prepnuti do stavu "available"
				MOV 	R10, #light_on ; nastaveni stavu "svetel" na zapnuto
				BL LEDB_ON				; aktivace modre LEDky ("svetla sviti")
				BL LEDG_ON				; aktivace zelene LEDky ("svetla sviti")
				MOV R5, R4				; SW counter, odcitani od nastavene konstanty v R4, navrat na pocatecni hodnotu
				MOV R8, #0				; nulovani SW counteru
				
				
SKIP_UART_3
				BL TO_DECADIC
				BL LCD_DISPTIME
				BL USART_DISPTIME
NO_RDY_REC									;cekani na prijem bajtu
				POP		{R1, R2, R3, PC}
;**************************************************************************************************
				align 4  ; zarovnani na hranici 4 Byte
				ENDP ; informace pro prekladac konec procedury, funguje to i bez PROC a ENDP					

;*********************************************************************************************
;* Jmeno funkce		: TRAN_USART_TEXT
;* Popis			: Podprogram pro vyslani retezce dat pres USART1
;* Vstup			: R3 = adresa retezce
;* Vystup			: Zadny
;* Komentar			: Je vyslana skupina bajtu az po zarazku ( 0 ) 	
;*********************************************************************************************
TRAN_USART_TEXT	PROC		  			; Navesti zacatku podprogramu + informace pro prekladac ( PROC)
				PUSH	{R0, R1, R2, LR}			
				MOV		R1, R3
NEXT_B	 						
				LDRB	R3,[R1],#1 			; nacteni znaku, a inkrementace ukazatele
				CBZ		R3, END_SEND 		; je-li znak null, konec
				BL	 	TRAN_USART			; vyslani znaku pres USART
				B	 	NEXT_B	 			; dalsi znak (bajt)
END_SEND		
				POP		{R0, R1, R2, PC}
;**************************************************************************************************
				align 4  ; zarovnani na hranici 4 Byte
				ENDP ; informace pro prekladac konec procedury, funguje to i bez PROC a ENDP					

;*********************************************************************************************
;* Jmeno funkce		: USART_DISPTIME
;* Popis			: Podprogram pro zobrazeni casu na terminalu
;* Vstup			: Zadny, cte data (cas) ulozeny v RAM
;* Vystup			: Zadny
;* Komentar			: -
;*********************************************************************************************
USART_DISPTIME	PROC			  			; Navesti zacatku podprogramu + informace pro prekladac ( PROC)
				PUSH	{R0, R1, R2, LR}			
				
				LDR		R3, =ansi_row2			; nacteni adresy retezce, posun kurzoru na druhy radek
				BL		TRAN_USART_TEXT			; vyslani textoveho retezce
				
				CMP R0, #state_running
				BNE UART_SKIP0
				; je ve stavu running
				
				; zapis textu na terminal
				LDR R3, =hlaseni_run
				BL		TRAN_USART_TEXT			; vyslani textoveho retezce
				
				LDR.W R1, =moje_RAM		; nacteni adresy mojeRAM do R1
				LDRB R3, [R1,#1]		; nacteni bytu z pameti moje_RAM+0 do R3, jde o cislici (desitky/jednotky)
				BL TRAN_USART			; vyslani bytu na usart
				LDR.W R1, =moje_RAM		; nacteni adresz mojeRAM do R1
				LDRB R3, [R1,#3]		; nacteni bytu z pameti moje_RAM+2 do R0, jde o cislici (desitky/jednotky)
				BL TRAN_USART			; vyslani bytu na usart
				
UART_SKIP0
				CMP R0, #state_setting
				BNE UART_SKIP1
				; je ve stavu setting
				LDR		R3, =ansi_row2			; nacteni adresy retezce, posun kurzoru na druhy radek
				BL		TRAN_USART_TEXT			; vyslani textoveho retezce
				
				; zapis textu na terminal
				LDR.W R3, =hlaseni_set
				BL		TRAN_USART_TEXT			; vyslani textoveho retezce
				
				LDR.W R1, =moje_RAM		; nacteni adresz mojeRAM do R1
				LDRB R3, [R1,#0]		; nacteni bytu z pameti moje_RAM+1 do R3, jde o cislici (desitky/jednotky)
				BL		TRAN_USART	; vyslani textoveho retezce
				LDR.W R1, =moje_RAM		; nacteni adresz mojeRAM do R1
				LDRB R3, [R1,#2]		; nacteni bytu z pameti moje_RAM+3 do R3, jde o cislici (desitky/jednotky)
				BL		TRAN_USART	; vyslani textoveho retezce
UART_SKIP1
				
				CMP R0, #state_available
				BNE UART_SKIP2
				; je ve stavu ready (available)
				; zapis textu na terminal
				LDR.W R3, =hlaseni_ready
				BL		TRAN_USART_TEXT			; vyslani textoveho retezce
				
				LDR.W R1, =moje_RAM		; nacteni adresz mojeRAM do R1
				LDRB R3, [R1,#1]		; nacteni bytu z pameti moje_RAM+1 do R3, jde o cislici (desitky/jednotky)
				BL		TRAN_USART			; vyslani textoveho retezce
				LDR.W R1, =moje_RAM		; nacteni adresz mojeRAM do R1
				LDRB R3, [R1,#3]		; nacteni bytu z pameti moje_RAM+3 do R3, jde o cislici (desitky/jednotky)
				BL		TRAN_USART			; vyslani textoveho retezce
UART_SKIP2
				; doplnit mezerami 
				LDR.W R3, =hlaseni_clear		; doplneni mezerami
				BL		TRAN_USART_TEXT			; vyslani textoveho retezce

				POP		{R0, R1, R2, PC}
;**************************************************************************************************
				align 4  ; zarovnani na hranici 4 Byte
				ENDP ; informace pro prekladac konec procedury, funguje to i bez PROC a ENDP					

;*********************************************************************************************
;* Jmeno funkce		: TRAN_USART
;* Popis			: Podprogram pro vyslani bajtu pres USART1
;* Vstup			: R3 = bajt k vyslani
;* Vystup			: Zadny
;* Komentar			: Je vyslana skupina bajtu az po zarazku ( 0 ) 	
;*********************************************************************************************
TRAN_USART		PROC		  			; Navesti zacatku podprogramu + informace pro prekladac ( PROC)
				PUSH	{R0,R1, R2, LR} 
NO_RDY_TRAN	
				LDR 	R0, =USART_SR
				LDR 	R2, [R0] 		
				TST 	R2, #0x40 			; test vyprazdeni vysilaciho bufferu 
				BEQ 	NO_RDY_TRAN			; skok pri nevyprazdnenem bufferu
				LDR 	R0, =USART_DR 	
				STRB 	R3, [R0] 			; ulozeni bajtu do vysilaciho registru
				LDRB 	R2, [R0] 			; prazdne vycteni DR a nulovani priznaku
							
				POP 	{R0, R1, R2, PC} 
;**************************************************************************************************
				align 4  ; zarovnani na hranici 4 Byte
				ENDP ; informace pro prekladac konec procedury, funguje to i bez PROC a ENDP					
					
;**************************************************************************************************
;* Jmeno funkce		: DELAY
;* Popis			: Softwarove zpozdeni procesoru
;* Vstup			: R3, pocet iteraci smycky
;* Vystup			: Zadny
;* Komentar			: Podprodram zpozdi prubech vykonavani programu	
;**************************************************************************************************
DELAY 			PROC		  			; Navesti zacatku podprogramu + informace pro prekladac ( PROC)
				PUSH	{LR}				; Ulozeni hodnoty navratove adresy - LR do zasobniku 
										; 
WAIT			SUBS	R3, R3, #1		; Odecteni 1 od R3,tj. R3 = R3 - 1 a nastaveni priznakoveho registru   	
				BNE		WAIT			; Skok na navesti pri nenulovosti R3 (skok dle priznaku)
				
				POP		{PC}		; jednodussi varianta POP misto predchozich dvou radku
;**************************************************************************************************
				align 4  ; zarovnani na hranici 4 Byte
				ENDP ; informace pro prekladac konec procedury, funguje to i bez PROC a ENDP


gener_zn 
			DCB nula 		; prekladac vlozi hodnotu 2_00111111
			DCB jednicka
			DCB dvojka
			DCB trojka
			DCB ctyrka
			DCB petka
			DCB sestka
			DCB sedmicka
			DCB osmicka
			DCB devitka
			DCB tecka

hlaseni_ready 	DCB "READY TIME=", 0x0
hlaseni_set  	DCB "SET TIME=", 0x0
hlaseni_run  	DCB "RUN TIME=", 0x0
hlaseni_name  	DCB "Petr Pojar", 0x0
hlaseni_clear 	DCB "   ", 0x0

hlaseni_usarton	DCB	" Cortex-M3 DISCOVERY -> SCHOD_AUTO_LCD",0xA, 0xD, 0; definovani konstanty retezce

ansi_row2 		DCB 0x1B,"[2;2H", 0x0 ; navrat kurzoru na zacatek DRUHEHO radku
ansi_row3 		DCB 0x1B,"[3;2H", 0x0 ; navrat kurzoru na zacatek TRETIHO radku
ansi_clear 		DCB 0x1B,"[2J", 0x0 ; clear screen
ansi_home 		DCB 0x1B,"[H", 0x0 ; clear screen
ansi_hidec 		DCB 0x1B,"[?25l", 0x0 ; hide cursor

					
				END						; Konec programu, dal jiz kod prekladac neprelozi
