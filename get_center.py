import xml.etree.ElementTree as ET

def find_average_center(input_file):
    tree = ET.parse(input_file)
    root = tree.getroot()

    x_sum = 0
    y_sum = 0
    count = 0

    for edge in root.findall('edge'):
        if 'shape' in edge.attrib:
            shape = edge.attrib['shape'].split()
            coords = [tuple(map(float, coord.split(','))) for coord in shape]
            x, y = coords[0]
            x_sum += x
            y_sum += y
            count += 1

    avg_x = x_sum / count
    avg_y = y_sum / count

    return avg_x, avg_y

if __name__ == "__main__":
    import sys
    import os
    
    # Get the network file name from command line argument or use default
    if len(sys.argv) > 1:
        INPUT_FILE = sys.argv[1]
    else:
        # Look for the network file in current directory
        net_files = [f for f in os.listdir('.') if f.endswith('_full.net.xml')]
        if net_files:
            INPUT_FILE = net_files[0]  # Use the first one found
        else:
            print("Error: No network file found. Please provide the network file as argument.")
            sys.exit(1)
    
    if not os.path.exists(INPUT_FILE):
        print(f"Error: Network file '{INPUT_FILE}' not found.")
        sys.exit(1)
        
    center_x, center_y = find_average_center(INPUT_FILE)
    print(f"Suggested center: ({center_x}, {center_y})")

