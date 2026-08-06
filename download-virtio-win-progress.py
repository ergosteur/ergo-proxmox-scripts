#!/usr/bin/env python3

# install libraries
# apt install python3-requests python3-bs4 python3-tqdm
import os
import requests
from bs4 import BeautifulSoup
import re
from tqdm import tqdm
import argparse

# Argument parser to handle --cron flag and directory path
parser = argparse.ArgumentParser(description='Download latest virtio ISO.')
parser.add_argument('--cron', action='store_true', help='Run in cron-friendly mode with minimal output')
parser.add_argument('--dir', type=str, default='.', help='Directory to save the ISO file')
args = parser.parse_args()

# Ensure the directory exists
if not os.path.exists(args.dir):
    os.makedirs(args.dir)

# URL for the latest virtio ISO downloads
url = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/'
response = requests.get(url)
soup = BeautifulSoup(response.text, 'html.parser')

latest_iso_link = None
version_number = None

# Find the latest ISO link by matching filenames ending in '.iso'
for link in soup.find_all('a', href=True):
    if link['href'].endswith('.iso'):
        latest_iso_link = link
        version_number = re.search(r'\d+\.\d+\.\d+', link['href']).group()
        iso_name = f"virtio-win-{version_number}.iso"
        break

if latest_iso_link and version_number:
    print(f"Version Number: {version_number}")

    # Construct the download URL
    iso_url = url + latest_iso_link['href']
    iso_path = os.path.join(args.dir, iso_name)

    try:
        response = requests.get(iso_url, stream=True)
        total_size = int(response.headers.get('content-length', 0))
        
        if os.path.exists(iso_path):
            local_size = os.path.getsize(iso_path)
            if local_size == total_size:
                if not args.cron:
                    print(f"File {iso_path} already exists and is the same size. Skipping download.")
            else:
                if not args.cron:
                    print(f"File {iso_path} exists but has a different size. Redownloading...")
        else:
            if not args.cron:
                print(f"File {iso_path} does not exist. Downloading...")

        if not os.path.exists(iso_path) or local_size != total_size:
            with open(iso_path, 'wb') as f, tqdm(
                    total=total_size, unit='B', unit_scale=True, desc=iso_name, ncols=80, disable=args.cron) as progress_bar:
                for chunk in response.iter_content(chunk_size=8192):
                    if chunk:
                        f.write(chunk)
                        if not args.cron:
                            progress_bar.update(len(chunk))

            print(f"Downloaded ISO file successfully. Saved to {iso_path}")
    except requests.exceptions.RequestException as e:
        print(f"Error downloading the ISO file: {e}")
else:
    print("No ISO file found or unable to extract version number.")
