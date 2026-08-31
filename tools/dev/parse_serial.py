#!/usr/bin/env python3
import sys
data = open('/tmp/serial.log', 'rb').read().decode('ascii', 'ignore')
i = data.find('ZigOS kernel starting')
if i >= 0:
    print(data[i:i + 4000])
else:
    print('NO KERNEL START found. Log tail:')
    print(data[-3000:])
