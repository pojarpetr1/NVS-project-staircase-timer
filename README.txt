Projekt z předmětu Návrh vestavných systémů. Projekt pro Keil uVision, psaný v assembleru pro STM32F100RB, implementující schodišťový automat s nastavitelnou dobou sepnutí. Čas lze nastavovat pomocí tlačítek, rotačního enkodéru nebo přes UART terminál v rozsahu 1–99 s. Aktuální stav automatu a nastavený nebo zbývající čas jsou zobrazovány na LCD displeji a současně v terminálu.

Program využívá Timer 3 pro obsluhu enkodéru a USART1 pro sériovou komunikaci. Nastavený čas je rovněž ukládán do interní Flash paměti, takže zůstává zachován i po restartu.
